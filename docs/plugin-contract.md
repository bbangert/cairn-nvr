# Cairn plugin contract

An inference plugin is an external process, one per camera, supervised by
Cairn. It receives the camera's H.264 video as RTP over UDP, runs whatever
detection it wants, and prints detections as ndjson on stdout. That is the
whole interface — any language, any runtime, any model.

Reference implementations:

- `priv/plugins/mock/mock_plugin.exs` — deterministic timeline replay
  (used by Cairn's own tests; ignores the video entirely).
- `plugins/cpu-reference/` — real CPU inference (PyAV decode → ONNX),
  doubles as the documented example.

## Inputs

### argv

Cairn appends these arguments to the configured command
(`cameras[].plugin` in `config.yml`):

| flag | value |
|------|-------|
| `--camera-id` | the camera's config id (echo it back in output if you like; Cairn tracks per-port anyway) |
| `--udp-port` | UDP port on `127.0.0.1` where H.264 RTP arrives |
| `--min-score-json` | JSON object of label → min score (e.g. `{"default":0.5,"person":0.6}`) — pre-filtering in the plugin is optional; Cairn enforces it regardless |

Anything you put in the configured command before these (model paths,
device selection, `--timeline`, …) is passed through untouched.

### Video input

- H.264 RTP/UDP on `127.0.0.1:{udp-port}`, payload type 96, 90 kHz clock.
- Sent by ffmpeg's `-f rtp` output (codec copy of the camera stream, or
  the transcoded stream when the camera opts into transcode).
- No RTCP, no handshake: packets flow whether or not you listen.
- Most decoders need an SDP to consume raw RTP; see the reference plugin
  for the standard generated-SDP trick.

## Output

One JSON object per line on **stdout** (ndjson), flushed per line, at most
8192 bytes per line:

```json
{"camera_id": "front_door", "pts": 90000, "dets": [
  {"label": "person", "score": 0.87, "bbox": [0.12, 0.4, 0.2, 0.5]}
]}
```

- `pts` — the RTP timestamp (90 kHz) of the analyzed frame. Required.
- `dets` — possibly empty list. `label` string, `score` 0..1, `bbox`
  `[x, y, w, h]` normalized to 0..1.
- Emit at whatever rate you sample; ~5 fps is plenty. Empty `dets` lines
  are fine (and useful as a liveness signal).
- Malformed lines are logged and dropped by Cairn — they will not crash
  anything, but they also won't detect anything.

## Logging

**stderr only.** Cairn redirects it to `{data_dir}/log/plugin-{camera}.log`.
Anything you print to stdout that isn't contract ndjson is dropped with a
warning.

## Lifecycle

- Started when the camera starts; killed (SIGTERM) when the camera stops.
- If you exit — crash or normal — Cairn restarts you with jittered backoff
  (1s → 30s). Exiting on unrecoverable errors is the correct behavior.
- Be idempotent on restart: you may be re-run mid-stream at any time, and
  you must cope with joining an RTP stream mid-GOP (decoders resync on
  the next keyframe).
- Config (min scores, camera id, port) only changes across restarts —
  never mid-run.
