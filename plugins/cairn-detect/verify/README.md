# cairn-detect verify harness

```
./feed.py --port 17000 --duration 20
some_plugin --udp-port 17000 --camera-id test | tee run.ndjson | ./validate_ndjson.py
./compare_runs.py --a python_run.ndjson --b rust_run.ndjson
```

End-to-end: terminal 1 feeds a fixture clip as RTP; terminal 2 runs the
plugin under test against that port, tees its stdout to a file, and
validates it live:

```
# terminal 1
./feed.py --port 17000 --duration 30

# terminal 2
python3 ../../cpu-reference/main.py --model yolov8n.onnx --labels coco.names \
    --camera-id test --udp-port 17000 --min-score-json '{}' \
  | tee python_run.ndjson | ./validate_ndjson.py

# terminal 1 (rerun for the other plugin), then:
./compare_runs.py --a python_run.ndjson --b rust_run.ndjson
```
