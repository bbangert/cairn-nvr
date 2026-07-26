# Rust review — multiplexed runtime (`plugins/cairn-detect`)

Scope: working-tree diff vs HEAD — new `src/multiplex.rs`, modified `src/main.rs`,
`src/rtp.rs`, `src/infer.rs`. Read-only; nothing was changed.

## Verdict

No BLOCKER. The thread/channel machinery is correct: the `Select` bookkeeping,
the disconnect-and-remove path, the never-exit stream loop, and the
`run_single` preservation all hold up under the scenarios I traced. Findings
below are 4 WARNINGs (2 of them behavioural, worth fixing before this ships)
and 5 SUGGESTIONs.

## What I verified as correct (no action)

- **No send-side deadlock.** `decode::run` uses `try_send`
  (`decode.rs:352-366`), never a blocking `send`, so dropping a slot's
  `Receiver` — which happens when `infer_loop` returns and `multiplex::run`'s
  `slots` vec drops (`multiplex.rs:80,95`) — surfaces as
  `TrySendError::Disconnected` and cannot park a decode thread. The
  "receiver dropped while producer blocks on send" hazard does not exist here.
- **`Select` index mapping is sound.** `Slots::next` (`multiplex.rs:198-217`)
  rebuilds `Select` each call, registering in `self.live` order, so
  `operation.index()` → `self.live[position]` → `self.slots[slot]` is the same
  channel that was selected. crossbeam panics if `SelectedOperation::recv` is
  handed a different channel; it never is. `SelectedOperation` is always
  completed (both arms call `recv`), so the "dropped without completing" panic
  cannot fire. `live.remove(position)` mutates only after the borrow of
  `self.live` from the registration loop ends. The `while !self.live.is_empty()`
  guard prevents `Select::select()` on an empty set (which blocks forever).
- **Camera identity under `Select` is right.** `slot` indexes `specs` and
  `floors` in the same order they were built (`multiplex.rs:79-93`,
  `162-165`), and slot indices are never renumbered — `live` holds original
  indices and only shrinks. `emit::emit(&mut out, &specs[index].id, ...)`
  therefore always stamps the right camera. `floors_for` preserves order
  identically (`multiplex.rs:65-70`). Tests at `multiplex.rs:275-323` cover
  the interesting cases (including a slot that dies mid-iteration).
- **Panic in a decode thread drops its slot, not the process.**
  `Cargo.toml` has no `panic = "abort"`, so unwinding drops the closure's
  `tx`, disconnecting the `Receiver` — exactly the intended semantics. The
  `stream_loop` `loop {}` never returns, so disconnect ⟺ panic.
- **`run_single` is behaviourally identical to old `run()`.** Diffed against
  `git show HEAD:plugins/cairn-detect/src/main.rs`: same ordering (floors →
  labels → detector → banner → spawn infer thread → `open_stream` → decode →
  `drop(tx)` → `join`), same error propagation, same `open_stream` 12×5s
  budget. The only change is `min_score_json` moving from clap
  `default_value = "{}"` to `Option` with `.unwrap_or("{}")` at
  `main.rs:125` — semantically equivalent (clap treats an absent flag and
  `--min-score-json '{}'` the same either way). `ScoreFloors::parse` still
  produces byte-identical floors via `from_map` (`infer.rs:30-42`).
- **clap conflict/required semantics.** `required_unless_present` /
  `conflicts_with` use derive arg ids (snake_case field names), which is
  correct. Neither form can be half-specified, and `--min-score-json` is
  correctly conflicting-but-not-required. Covered by `main.rs:219-241`.
- **Wire shape matches Cairn.** `Cairn.PluginGroupPort.build_argv/1`
  (`lib/cairn/plugin_group_port.ex:51`) `Jason.encode!`s plain maps built at
  `lib/cairn/config.ex:234` as `%{id:, udp_port:, min_score:}`, which is
  exactly `CameraSpec`. `min_score` is never `nil`
  (`lib/cairn/config/camera.ex:83` defaults it to `%{"default" => 0.5}`), so
  `#[serde(default)]` on `CameraSpec.min_score` — which would *reject* an
  explicit `null` — is never exercised with null. `CameraSpec` does not use
  `deny_unknown_fields`, satisfying the contract's "ignore fields you do not
  recognize" rule (`docs/plugin-contract.md:180`).

---

## WARNING

### W1 — `multiplex.rs:83-86` "latest sample wins" is the opposite of what the code does

The comment says *"bounded(1) per camera: latest sample wins"*. On
`TrySendError::Full` (`decode.rs:354-364`) the **new** sample is discarded and
the **older** one stays in the slot. It is oldest-wins, not latest-wins.

Failure scenario: 6-camera group, CPU inference at ~120 ms/pass. The infer
loop services ~8 samples/s against 30 offered/s, so every slot is nearly
always occupied. A person walks into frame on `driveway`; that frame is
produced, the slot already holds a 700 ms-old frame, and the new one is
dropped. The detection Cairn receives for that pts window describes the scene
up to `N × inference_latency` earlier. Event start times drift by most of a
second and the effect scales linearly with group size — i.e. it gets worse
exactly as the feature gets used. Single-camera mode has the same code but
`N = 1`, so it was never visible.

Fix is small: on `Full`, drain the slot and re-`try_send` (making it genuinely
latest-wins), or correct the comment and accept the lag explicitly. Either
way the comment must stop claiming a property the code does not have.

### W2 — `infer.rs:89` + shared `Detector`: one CPU ONNX session is the group's hard capacity ceiling, with no guard rail

`Detector::open` registers only `ort::ep::CPU`. `multiplex::infer_loop` runs
every member through that single `&mut Detector` serially
(`multiplex.rs:162-166`). A 640×640 YOLO CPU pass is ~50–150 ms, so total
group throughput is roughly 7–20 inferences/s against an offered load of
`5 × N`. A group of 4+ cameras is saturated by construction.

Failure scenario: an operator points 8 cameras at one `plugins:` group,
expecting the whole point of multiplexing (share the model). Nothing fails.
Every camera silently drops ~75% of its samples; the only signal is a
per-stream `"inference behind: N samples skipped so far"` line every 50 drops
(`decode.rs:361-363`), buried in a shared group log alongside 7 other
cameras'. Detection recall degrades across the board with no error, no exit,
and no metric.

At minimum this needs a documented member-count guidance in
`docs/plugin-contract.md` and a startup warning when `specs.len()` exceeds
what one session can plausibly serve. Ideally the group log should carry an
aggregate "group is inference-bound: X% of samples dropped over the last
minute" line rather than N independent per-stream counters.

### W3 — `multiplex.rs:211` a dead slot is reported by index, not camera id

```rust
eprintln!("camera slot {slot}: decode thread is gone");
```

`Slots` is generic over `T` and has no access to `specs`, so the one line
telling an operator that a camera is permanently dead names it as `slot 3`.

Failure scenario: `rgb_to_chw` panics on a stride shorter than
`INPUT_SIZE * 3` (`decode.rs:277`) for one camera. That camera stops
producing detections *forever* — the process keeps running by design, Cairn
sees a healthy group, and the group log contains one line naming a slot
number that appears nowhere in the user's YAML. Diagnosis requires counting
positions in `cameras:`.

The disconnect is detected inside `infer_loop`'s `for` loop, where `specs` is
in scope — return the index and log `specs[index].id` there, or pass the ids
into `Slots`. (The default panic hook does print `thread 'stream-front'
panicked at …`, so the id is technically recoverable, but only if the panic
line is still in the log.)

### W4 — `multiplex.rs:32-36` re-open backoff roughly doubles recovery time for a camera that comes back

`open_stream_once` → `open_stream_within(port, 1)` (`rtp.rs:146-148`) inherits
the 30 s socket `timeout` (`rtp.rs:64`), so a dark camera's *failed open
already costs ~30 s*. `stream_loop` then sleeps a further `delay`, doubling to
`REOPEN_MAX = 30 s` (`multiplex.rs:130-131`).

Failure scenario: a member's ffmpeg crashes and Cairn's backoff brings it back
5 s later. The plugin is mid-30 s-open when it dies, fails, sleeps 30 s, opens
again (succeeds after the probe). Worst case ~60–70 s of no detection on a
camera that was only down for 5 s. Single-camera mode recovers faster
(`open_stream` retries every 5 s, `rtp.rs:16-17`), so multiplexed mode is
strictly worse at the thing the docs call routine
(`docs/plugin-contract.md:212-216`, "a stopped camera is routine").

The backoff is also guarding nothing expensive — one socket bind plus a
timeout that is itself the rate limiter. Capping `REOPEN_MAX` at ~5–10 s (or
dropping the sleep entirely and relying on the 30 s open timeout) would cut
worst-case recovery roughly in half with no added load.

---

## SUGGESTION

### S1 — `multiplex.rs:49-62` duplicate `udp_port` is not rejected, only duplicate `id`

`parse_specs` rejects repeated ids but not repeated ports, and the port is the
load-bearing resource. Two members on the same port (or on `p` and `p+1`,
since the SDP demuxer also binds `port + 1` for RTCP, `rtp.rs:21-23`) means
one thread's bind fails with `EADDRINUSE` forever. Because open failures are
non-fatal by design, that camera is permanently dark with only a throttled
stderr line — a config bug that should be a startup error instead becomes a
silent runtime hole. Add a second `HashSet` over `udp_port` and `udp_port + 1`
and `bail!` on collision, next to the existing id check.

### S2 — `multiplex.rs:111-114` the healthy-run clock includes the open attempt

`started` is taken before `open_and_run`, so `HEALTHY_RUN` measures
open + probe + stream time, not stream time. Today the margin holds (30 s
socket timeout + 10 s `analyzeduration` < 60 s), so a dark camera cannot
falsely reset its backoff — but the invariant is implicit and one bump to
`timeout` or `analyzeduration` past ~60 s silently pins a permanently dark
camera at `REOPEN_MIN` forever. Starting the clock after a successful open
(or on the first sample sent) makes the property explicit.

### S3 — `multiplex.rs:118-122` the `Ok(())` arm is unreachable

`open_and_run` tail-calls `decode::run`, which only ever returns `Err`
(`decode.rs:308-368` — the loop's only exits are `?` and `bail!`). The
`"stream ended"` branch is dead. Harmless, but it implies a normal-completion
path that does not exist.

### S4 — `rtp.rs:179-182` "after 1 attempts" in the multiplexed error message

`open_stream_once` produces `"no decodable stream on udp port 17000 after 1
attempts: …"` on every cycle. Minor, but this is the line an operator reads
most often in a group log; a single-attempt caller reads better as just the
underlying error.

### S5 — a partially-dead group is invisible to Cairn

Per design intent the process must not exit when one slot dies, so after a
decode-thread panic Cairn sees a running group serving N−1 cameras with no
signal at all — no exit, no status, nothing on the `/api` surface. Worth a
follow-up: a periodic stderr line naming the still-live members, or a
heartbeat ndjson line, so "camera stopped producing detections" is
distinguishable from "camera is quiet" without reading the group log.

---

## Notes on things I deliberately did not flag

- Rebuilding `Select` per sample (`multiplex.rs:200-203`) is O(N) allocation
  at ≤ `5 × N` Hz — irrelevant.
- `ScoreFloors.by_label` retaining the `"default"` key means
  `floor_for("default")` returns the default; pre-existing and harmless unless
  a model has a class literally named `default`.
- `thread::Builder::name` panics on interior NUL, but camera ids are regex-
  validated upstream.
- Detached `JoinHandle`s (`multiplex.rs:89-92`) are correct here — the threads
  are meant to outlive any join point and the process exits via
  `std::process::exit`.
