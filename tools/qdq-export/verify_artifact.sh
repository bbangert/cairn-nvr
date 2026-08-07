#!/bin/sh
# verify_artifact.sh <model.onnx> [extra plugin flags...]
#
# One-shot decode verification on the CPU EP: run the release plugin on a
# loopback RTP port, feed it a recorded fixture clip, validate the ndjson
# stream, and print a label histogram. This is verify/'s documented
# two-terminal flow collapsed into one script for per-artifact checks —
# it answers "does this artifact still detect the same things", never
# byte-identity (see verify/README.md on the wall-clock sample gate).
#
# Env: CLIP (fixture mp4; default: newest under data/events/reolink_main
# next to the repo root), PORT (default 17300), SECS (default 30),
# MIN_SCORE_JSON (default '{}' — the plugin's own 0.5 default floor; a
# quantized artifact whose scores dip near that floor reads as "no
# detections", so diagnose with e.g. '{"default": 0.2}').
set -eu
MODEL=$1
shift
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN="$ROOT/plugins/cairn-detect/target/release/cairn-detect"
VERIFY="$ROOT/plugins/cairn-detect/verify"
PORT=${PORT:-17300}
SECS=${SECS:-30}
MIN_SCORE_JSON=${MIN_SCORE_JSON:-'{}'}
CLIP=${CLIP:-}
if [ -z "$CLIP" ]; then
  CLIP=$(ls -t "$ROOT"/data/events/reolink_main/*.mp4 2>/dev/null | sed -n 1p)
fi
[ -x "$BIN" ] || { echo "no release binary at $BIN — cargo build --release first"; exit 1; }
[ -n "$CLIP" ] && [ -f "$CLIP" ] || { echo "no fixture clip (set CLIP=)"; exit 1; }

OUT=$(mktemp -t verify_artifact_XXXXXX.ndjson)
ERR="${OUT%.ndjson}.err"
PLUGIN=""
trap 'kill "${PLUGIN:-}" 2>/dev/null; rm -f "$OUT" "$ERR"' EXIT

# The brace group is the control channel: the plugin emits nothing
# without a stream epoch, and exits on stdin EOF — the trailing sleep
# bounds the run (verify/README.md). Its margin over SECS must exceed
# the startup wait below, or a slow model load truncates the feed.
{
  echo '{"spec":"cairn.plugin","version":1,"type":"stream.started","camera_id":"test","stream_epoch":"01K0QDQVERIFY0000000000000","rtp":{"clock_rate":90000}}'
  sleep $((SECS + 30))
} | "$BIN" --model "$MODEL" --labels "$ROOT/plugins/cairn-detect/coco.names" \
    --camera-id test --udp-port "$PORT" --min-score-json "$MIN_SCORE_JSON" \
    --decoder sw "$@" > "$OUT" 2> "$ERR" &
PLUGIN=$!

# Feed only after the model has loaded: the RTP listener opens after it.
# 25s ceiling, under the control channel's 30s margin above.
for _ in $(seq 50); do
  grep -q "cairn-detect up:" "$ERR" && break
  sleep 0.5
done
grep -q "cairn-detect up:" "$ERR" || { cat "$ERR"; exit 1; }

"$VERIFY/feed.py" --port "$PORT" --duration "$SECS" --clip "$CLIP" --loops 3 || true
wait "$PLUGIN" || true

grep "cairn-detect up:" "$ERR"
"$VERIFY/validate_ndjson.py" < "$OUT"
# Label histogram: the sanity signal a human reads ("person 143, car 12").
python3 - "$OUT" <<'EOF'
import collections, json, sys
labels = collections.Counter()
frames = 0
for line in open(sys.argv[1]):
    msg = json.loads(line)
    if msg.get("type") == "frame.objects":
        frames += 1
        for det in msg["objects"]:
            labels[det["label"]] += 1
print(f"{frames} object frames; labels: "
      + (", ".join(f"{l} x{n}" for l, n in labels.most_common(8)) or "NONE"))
EOF
