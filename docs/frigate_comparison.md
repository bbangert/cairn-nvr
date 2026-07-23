# Storage and memory: comparison with Frigate

A side-by-side analysis of how Frigate handles fragment caching, recording, shared memory, and persistent state, contrasted with the in-BEAM ring-buffer architecture documented in `architecture.md`. The goal is to surface where the two approaches genuinely differ and why, so that decisions in our design are informed by Frigate's lessons (where applicable) rather than inheriting them by default.

This report reflects Frigate's behavior as of release 0.16 (current stable, March 2026 source index), drawing primarily from the project's installation docs, recording docs, the `record/maintainer.py` and `video.py` source modules surfaced through DeepWiki, and a representative sample of community discussions about real-world failure modes.

## TL;DR

Frigate and our design solve the same problem with two different sets of tradeoffs forced by their language and runtime choices.

Frigate uses **two memory regions plus a SQLite catalog**: POSIX shared memory (`/dev/shm`) for raw decoded frames during inference, and a tmpfs-backed disk cache (`/tmp/cache`) for encoded recording segments awaiting validation. Both exist because Python's multi-process architecture needs explicit IPC, and because passing decoded frames or 10-second mp4 segments through Python message queues would be prohibitive.

Our design uses **one in-BEAM ring buffer** for encoded fragments, with raw decoded frames living entirely inside the inference plugin's GStreamer pipeline (never crossing the BEAM/plugin boundary). We don't need a tmpfs cache because there's no separate validation stage — fragments are valid by construction at the point ffmpeg emits them, and BEAM's reference-counted binaries mean fan-out to multiple subscribers is free.

The differences aren't because Frigate got something wrong — they're forced by the underlying runtime. Frigate's design is a competent solution to "Python plus multiprocessing." Ours is a competent solution to "BEAM plus ports."

## Frigate's storage architecture

### The three memory regions

Frigate maintains three distinct storage areas with very different roles, sizes, and lifecycles:

| Region | Backing | Purpose | Default size | Lifecycle |
|---|---|---|---|---|
| `/dev/shm` | POSIX shared memory | Raw decoded YUV420 frames for inference | 64 MB (must increase) | Rotating ring per camera |
| `/tmp/cache` | tmpfs (recommended) | Encoded recording segments pending validation | 1 GB | Ephemeral, drains to `/media/frigate` |
| `/media/frigate` | Persistent disk | Validated mp4 segments, snapshots, exports, SQLite db | User-provided | Long-term, retention-policy-controlled |

These exist because Frigate's processes communicate by writing to known locations and signaling via queues, rather than passing payloads as messages. Each region has an explicit purpose and an explicit consumer.

### `/dev/shm`: raw decoded frames

This is the hottest data path. Frigate runs **two processes per camera**: a `CameraCapture` process that reads frames from ffmpeg's stdout, and a `CameraTracker` process that runs motion detection and feeds the object detector. Frames are decoded YUV420 at the camera's *detect* resolution (often a sub-stream at 1280×720 or smaller, separate from the recording resolution).

The `SharedMemoryFrameManager` allocates a rotating buffer per camera in `/dev/shm`. Each frame slot has a stable name (e.g. `camera_name_frame_N` for N in 0..19), and the capture process writes directly into the shared memory slot — `frame_buffer[:] = ...` — without copying. The tracker process reads the same memory after dequeuing the frame's name from the queue.

The size formula Frigate publishes is:

```
shm_size_per_camera = (width × height × 1.5 × shm_frame_count + 270480) bytes
total_shm_size = (per_camera × num_cameras) + 40 MB (logs)
```

At 720p with 20 frame slots per camera, each camera needs about 28 MB. At 1080p, ~62 MB. The default Docker shm-size of 64 MB is famously insufficient for anything beyond two 720p cameras, and "Bus error" crashes from undersized shm are one of the most common Frigate setup failures — there's a long-running thread of users hitting it, with the symptom often being unrelated to the cause.

Critically, `/dev/shm` is not a fallback — frames *must* live there because crossing process boundaries with raw frame data would mean memcpy of YUV420 buffers (1.5 MB at 720p, 3 MB at 1080p) at frame rate, which Python multiprocessing's pickle-based IPC cannot sustain.

### `/tmp/cache`: encoded recording segments

A separate region serves the recording pipeline. Frigate runs ffmpeg with the segment muxer, configured to emit roughly 10-second mp4 files into `/tmp/cache`. A dedicated `RecordingMaintainer` process polls this directory every 5 seconds, validates each segment, computes statistics, and copies valid segments to `/media/frigate/recordings/YYYY-MM-DD/HH/{camera}/MM.SS.mp4`.

The validation step is where the design gets interesting. ffmpeg can produce corrupt segments under various failure modes (camera disconnect mid-segment, hwaccel hiccup, etc.), and Frigate explicitly probes each cached segment with ffprobe before promoting it. Invalid segments are discarded; valid ones are re-muxed using `ffmpeg -i {cache} -c copy -movflags +faststart {final}` to relocate the moov atom for HTTP playback.

The cache exists because:

1. **Validation requires the complete segment.** ffprobe needs the file's metadata atoms, which for a non-faststart mp4 only land at the end. Validating mid-write is impossible.
2. **The faststart re-mux requires a separate output.** You can't transform an mp4 in place.
3. **Disk wear.** Writing every segment to permanent storage and then potentially deleting it would burn write cycles. tmpfs absorbs the churn.

The recommended cache size is 1 GB. At ~10 seconds per segment and typical bitrates this holds roughly 1–3 minutes of pre-validation buffer per camera, more than enough headroom for the 5-second maintenance loop.

### `/media/frigate`: persistent storage

The permanent layer holds:

- `recordings/YYYY-MM-DD/HH/{camera}/MM.SS.mp4` — validated 10-second segments, all of them, regardless of detection
- `clips/` — JPG snapshots of detected events
- `exports/` — user-initiated clip exports (concatenated from segments)
- `frigate.db` — SQLite database (more on this below)

Notably, **Frigate stores all 10-second recording segments to disk by default**, then applies retention policies after the fact based on whether each segment overlaps with motion or alert events. This is a deliberate design choice: segments are the granular unit, and the database tracks per-segment statistics (motion, objects, audio) so that retention can be computed retroactively.

The retention model is layered:

```yaml
record:
  enabled: True
  continuous:
    days: 3       # all video kept for 3 days
  motion:
    days: 7       # motion-overlapping segments kept for 7 days  
  alerts:
    retain:
      days: 30    # alert-overlapping segments kept for 30 days
```

Older segments are deleted by an async cleanup task that batches DELETEs against both filesystem and database. There's also an **emergency cleanup**: if free space drops below an hour's worth of recordings, Frigate aggressively purges oldest segments regardless of retention policy, logging a warning. This emergency mode exists because the alternative is the maintainer running out of cache space and crashing.

### The SQLite database

`frigate.db` (SQLite via Peewee ORM) is the catalog that ties everything together. Key tables:

- `Event` — one row per detected tracked object, with start/end timestamps, label, camera, confidence scores, thumbnail path, and a JSON `data` field for current tracking metadata
- `Recordings` — one row per 10-second recording segment with `path`, `start_time`, `end_time`, and statistics fields (motion score, object count, dBFS for audio)
- `ReviewSegment` — curated review entries grouping events into "alerts" vs "detections"
- `Timeline` — unified time-series of events from various sources
- `Export` — user-initiated clip export jobs

The database is single-file SQLite, intended to live on local storage (network shares cause "database is locked" errors per the docs). It has explicit WAL checkpoint logic and batch-delete patterns to keep the file from growing unbounded. The maintainer thread runs `PRAGMA wal_checkpoint(TRUNCATE)` when the WAL exceeds a configured size.

The database is the source of truth for what files exist on disk. If `frigate.db` is deleted, recordings become orphaned — they exist on disk but Frigate can't show them in the UI, and they require manual cleanup.

## Failure modes Frigate has accumulated

Frigate's error pages and forum threads tell the story of where this architecture stresses under load:

### "Too many unprocessed recording segments in cache"

The recording maintainer can't keep up. Cache fills, oldest segments are dropped before they can be validated and copied. Root causes:

- **Slow storage** for `/media/frigate` — most common. SD cards, NFS shares, USB 2.0 drives all show up here.
- **High CPU contention** preventing the maintainer from getting time slices.
- **Segment corruption** triggering ffprobe re-checks.

The maintainer's response is to drop segments rather than block, which preserves stability at the cost of recording gaps. When the storage pipe is too slow, you lose video, period.

### "Bus error" / shm exhaustion

The Python `SharedMemoryFrameManager` allocates frame buffers up-front based on configured detect resolution and camera count. If the actual `/dev/shm` size is smaller than required, allocation succeeds partially and writes fail with SIGBUS. The error message is generic and the cause is non-obvious — many users spend hours debugging this.

### Database lock errors

SQLite on network storage (or just under heavy concurrent access from multiple Frigate processes) hits "database is locked." The recommended fix is moving the database to local SSD via a separate volume mount.

### Out-of-memory under camera scale

Forum discussions cite users with 16+ cameras hitting OOM despite increasing the container limit to 8 GB. The combination of per-camera Python processes, `/dev/shm` allocations, ffmpeg processes, and detection model memory adds up faster than is intuitive. Frigate's own troubleshooting docs recommend setting `mem_swappiness: 0` and explicit memory+swap limits to make OOM behavior predictable rather than letting Linux's swap heuristics make things worse.

## How our design differs

### One memory region, not three

We have no equivalent of `/dev/shm`. Raw decoded frames live entirely inside the plugin's GStreamer pipeline, in DMA-BUF-backed `GstBuffer`s that the V4L2 decoder writes and the inference element consumes via mmap. They never cross the plugin/BEAM boundary. The plugin emits only JSON detection events to BEAM via stdout — small, infrequent, structured.

This is a direct consequence of the plugin contract design. Frigate needs `/dev/shm` because *its own process* (the tracker) does the inference and needs frames in a shared location. Our design pushes inference to a dedicated process that owns its decode pipeline end-to-end. The architectural cost is a more rigid plugin interface; the benefit is no IPC for raw frames.

We have no equivalent of `/tmp/cache` either. ffmpeg's output is fmp4 fragments piped to BEAM via the Port's stdout. Each fragment is independently valid by construction (`-movflags frag_keyframe+empty_moov+default_base_moof` produces self-contained `moof+mdat` pairs). There's no two-stage validate-then-promote pipeline because there's nothing to validate — if ffmpeg emitted bytes for a fragment, those bytes are the fragment.

Skipping the validation stage works for us because we're not making the same architectural commitment Frigate does:

- **Frigate stores everything.** Continuous recording is the default; segments must survive a validation pass because there's no other check on their integrity downstream.
- **We store events.** Fragments that aren't part of an active event are dropped from the ring after `pre_window` seconds and never written to disk. There's no archive integrity to protect.

Different durability requirements lead to different architectures. If we added continuous recording later, we'd need either Frigate-style validation or to trust ffmpeg's output unconditionally — the latter is reasonable for a single trusted ffmpeg producer per camera and is what we'd most likely do.

### BEAM binary semantics replace SHM tricks

The clever trick in Frigate's `SharedMemoryFrameManager` is zero-copy frame transfer between Python processes. BEAM gives this for free for binaries over 64 bytes: they live off-heap, are reference-counted, and "sending" one to another process is a pointer copy plus a refcount increment. Our ring buffer broadcasting the same fragment to N subscribers (live MSE viewer, WebRTC RTP source for one viewer, WebRTC RTP source for another viewer, an active event extractor) is structurally identical to Frigate's named-shm-slot pattern — except we get it from the runtime rather than implementing it.

The one place this breaks down is the encrypted output for WebRTC: SRTP encryption is per-peer, so each peer produces a unique byte stream. ex_webrtc handles this in Rust NIFs. Frigate has the same constraint and solves it by piping decoded frames through go2rtc, which also does per-peer encryption.

### No SQLite catalog (in this layer)

Frigate's database tracks every segment because every segment exists. Ours tracks events, not segments — the event extractor is the only writer to permanent storage, and it writes complete event clips with metadata at finalization time. The event index is small (dozens to thousands of rows, not millions), which means SQLite is appropriate but barely matters. We could use ETS, mnesia, or SQLite — the data volume doesn't force the choice.

The interesting consequence is that we don't have Frigate's "orphaned recordings if database is deleted" problem. Each event mp4 is self-describing (its filename includes the event ID, the file itself contains valid mp4 metadata). Rebuilding the index from disk after a database loss is feasible.

### No two-stage recording pipeline

Frigate's flow:

```
ffmpeg → /tmp/cache/{seg}.mp4 → maintainer polls → ffprobe validates
  → ffmpeg copy with +faststart → /media/frigate/recordings/...
  → INSERT INTO Recordings
```

Our flow:

```
ffmpeg → BEAM port stdout → ring buffer → 
  (event detected) → event extractor → /events/{id}.mp4
                                     → INSERT INTO event_index
```

The number of disk writes per fragment differs significantly:

- Frigate: write to cache (1), read for validation (1), write to permanent (1) = 3 disk operations per segment, **for every segment, always**
- Ours: zero disk operations during normal operation, fragments only written to disk if an event captures them

For a system that records continuously, Frigate's overhead is fine — it's amortized over the storage anyway. For a system that records only events, our reduced disk activity matters a lot, especially on hardware with limited write endurance (Nabu Casa devices include eMMC and SSDs where write amplification is a concern).

### Memory bound by pre_window, not retention

In Frigate, the relationship between memory and retention is:

- `/dev/shm` is bound by `cameras × resolution × frame_slots`. Doesn't scale with retention.
- `/tmp/cache` is bound by `cameras × maintainer_lag × bitrate`. Lag is bounded by maintainer health, so this is effectively `cameras × few_minutes × bitrate`.
- Disk is bound by `cameras × bitrate × retention_days`.

In our design:

- BEAM ring buffer is bound by `cameras × pre_window × bitrate`. Doesn't scale with retention or event duration.
- Disk is bound by `cameras × bitrate × event_density × retention_days`.

The math is similar but the constant factors are smaller for us because we don't keep frames in memory at all (Frigate's `/dev/shm` is doing real work) and because we don't continuously cache pre-validation (our equivalent of validation is "ffmpeg produced the bytes," which we trust).

## What Frigate gets right that we should learn from

It's worth being explicit about which Frigate decisions are good ideas independent of the runtime choice:

### Per-segment statistics enable retention to be retroactive

Frigate computes motion score, object count, and audio energy per segment and stores them in the `Recordings` table. This means retention policies can be evaluated as "delete segments where motion_score < threshold AND age > 7 days" against the database. Adding a new retention rule doesn't require re-processing video — the metadata is already there.

Our design doesn't need this for the event-clips-only model, but if we add continuous recording later, this is the right pattern: emit per-fragment stats from the plugin alongside detection events, and let retention queries use them.

### The maintainer pattern: one supervised process per role

Frigate's `RecordingMaintainer` is a dedicated long-running thread with a clear single responsibility, a tunable poll interval, explicit backpressure handling, and structured error logging. When the system falls behind, it's instrumented enough that operators can diagnose where.

Our equivalent — the `EventExtractor` — should be similarly instrumented. Per-event logs with file write durations, fragment counts, and finalization timing make the system debuggable when something goes wrong.

### Emergency cleanup is non-negotiable

Frigate's "if free space < 1 hour, purge oldest aggressively" is the kind of guardrail that prevents a recoverable problem (full disk) from becoming an unrecoverable one (process crash, requires restart). We need the equivalent for our event clips directory — at some configurable threshold, start deleting oldest events even if their retention policy hasn't expired, and surface this prominently in the UI.

### The faststart re-mux is worth doing for event clips

Frigate runs `-movflags +faststart` on every promoted segment so HTTP playback can begin without seeking. For our event clips, doing the same finalization step (or writing fmp4 in a way that's already faststart-equivalent) means the browser playback experience is smooth from the first frame.

### Treat the database as recoverable but not source-of-truth-only

Frigate's docs are explicit: if the database is lost, recordings are orphaned but not destroyed. The implication is that filenames and on-disk metadata should be sufficient to rebuild the index. This is a good discipline — we should maintain it for our event clips. Filenames should encode `{event_id}_{camera}_{timestamp}.mp4`, and the mp4 metadata should include camera ID and detection summary. A startup-time index rebuild from disk should always be possible.

## What we're explicitly not doing differently for its own sake

Some Frigate choices we should *not* deviate from just because we can:

- **Codec-copy by default.** Frigate transcodes only when forced. So do we.
- **10-second segment granularity.** Their choice; our 2-second fmp4 fragments are finer-grained because we need them for low-latency MSE preview, but for *event clip* storage, longer aggregated files (a single mp4 per event, not 30 small files) is the right shape.
- **Single retention policy per camera with per-label override.** Their config schema is good. We should adopt similar shape.
- **JPG snapshots alongside event clips.** Useful for thumbnails in the UI without decoding video. We should produce these from a keyframe in the event window.

## Quantitative comparison

For a representative deployment of 8 cameras at 1080p, 4 Mbps H.264, 30fps, with 10-second pre-window and 30-second post-window:

| Metric | Frigate (default config) | This design |
|---|---|---|
| Decoded-frame memory | ~500 MB `/dev/shm` (62 MB × 8) | 0 (in plugin GStreamer pipeline only) |
| Encoded-cache memory | 1 GB `/tmp/cache` tmpfs | ~40 MB BEAM ring buffer (8 × 4 Mbps × 10s ÷ 8) |
| Disk writes (steady state) | 100% of segments × ~3× ops | 0 unless event active |
| Disk capacity (24h continuous) | ~36 GB/camera = 288 GB total | 0 baseline + event clip volume |
| Disk capacity (24h event-only, 10% activity) | ~3.6 GB/camera = 28.8 GB total | ~3.6 GB/camera (similar) |
| Database row count after 30 days | ~2M Recordings rows + events | ~thousands of events only |
| OOM risk | Real, scales with cameras | Low, fixed by pre-window |
| Crash recovery | Validate cache, rebuild from db | Rescan event files, rebuild index |

The disk-capacity row is the most important one in practice. Frigate's continuous recording is doing real work — users *want* the ability to scrub back through time. Our event-only model is a different product positioning. Adding continuous recording is a feature, not a refactor; the architecture supports it as another fragment subscriber.

## Conclusion

Frigate's storage architecture is shaped by Python's process model and by a product decision to record everything by default. The two-region memory model (`/dev/shm` for frames, `/tmp/cache` for segments), SQLite catalog of every segment, and validation-then-promote pipeline are all sensible solutions to that problem space.

Our architecture is shaped by BEAM's native binary semantics and by a product decision to record only events. We replace `/dev/shm` with the plugin owning its decode pipeline, replace `/tmp/cache` with an in-process ring buffer, and replace the segment catalog with an event catalog. The complexity profile is significantly lower at the cost of giving up continuous recording as a built-in capability.

If continuous recording becomes a requirement, the path is clear: add a fragment subscriber that writes hour-rolled mp4 files to disk with per-fragment metadata, and adopt Frigate's retention-policy-against-metadata pattern. The ring buffer doesn't change. The event extractor doesn't change. We'd just be adding a third consumer alongside the live-view server and the event extractor — exactly the kind of extension the architecture is designed for.

The right framing is that Frigate has solved this problem competently within its constraints, and our design has different constraints that admit a simpler solution. Where Frigate has accumulated production wisdom about failure modes — emergency cleanup thresholds, maintainer instrumentation, faststart muxing, recoverable-database discipline — those lessons transfer directly and we should adopt them.