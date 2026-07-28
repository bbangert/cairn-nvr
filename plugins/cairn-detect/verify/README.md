# cairn-detect verify harness

```
./feed.py --port 17000 --duration 20
some_plugin --udp-port 17000 --camera-id test | tee run.ndjson | ./validate_ndjson.py
./compare_runs.py --a fp32.ndjson --b int8.ndjson
```

**The plugin emits no detections until it is told a stream epoch.** Cairn
sends one `stream.started` per camera on the plugin's stdin at spawn, and a
`frame.objects` line has no valid `stream_epoch` to carry before that — so a
run driven by hand has to supply the control line itself, and keep stdin open
afterwards so the reader thread does not see EOF.

End-to-end: terminal 1 feeds a fixture clip as RTP; terminal 2 runs the
plugin under test against that port, tees its stdout to a file, and
validates it live:

```
# terminal 1
./feed.py --port 17000 --duration 30

# terminal 2 — the brace group is the control channel: one epoch
# announcement, then a sleep that holds stdin open for the run
{ echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0TESTEPOCH00000000000000","rtp":{"clock_rate":90000}}'
  sleep 40; } \
  | ../target/release/cairn-detect --model ../yolov10n.onnx \
      --labels ../coco.names --camera-id test --udp-port 17000 \
      --min-score-json '{}' \
  | tee fp32.ndjson | ./validate_ndjson.py

# terminal 1 (rerun for the other model or decoder backend), then:
./compare_runs.py --a fp32.ndjson --b int8.ndjson
```

`validate_ndjson.py` exits nonzero if it saw no `frame.objects` line at all,
which is exactly what a forgotten control line looks like: `plugin.hello` and
`plugin.status` arrive, frames never do.
