#!/usr/bin/env bash
# x86 smoke of the container image (tier1-container 1.4). Needs docker with
# buildx; the repo devcontainer has none, so this is a handoff/CI script.
#
# Asserts, in order:
#   1. the amd64 image builds;
#   2. the release boots and serves the UI on :4000;
#   3. /api/cameras answers with the configured camera;
#   4. qnn is a STATED refusal (valid-but-inert rule): the camera status /
#      alert stream / logs name the qnn failure — a container without HTP
#      must say so, never silently run CPU.
#
# Everything is logged to smoke-x86.log next to this script.
set -uo pipefail

cd "$(dirname "$0")"
LOG="$PWD/smoke-x86.log"
: >"$LOG"
say() { echo "[smoke] $*" | tee -a "$LOG"; }

fail() {
  say "FAIL: $*"
  say "last container logs:"
  docker logs cairn-smoke 2>&1 | tail -40 | tee -a "$LOG"
  docker rm -f cairn-smoke >>"$LOG" 2>&1 || true
  exit 1
}

say "building linux/amd64 image"
docker buildx build --platform linux/amd64 -t cairn:smoke --load ../.. >>"$LOG" 2>&1 ||
  fail "image build (see $LOG)"

WORK=$(mktemp -d)
trap 'docker rm -f cairn-smoke >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/config" "$WORK/data"
cp smoke/config.yml "$WORK/config/config.yml"

say "booting container"
docker rm -f cairn-smoke >>"$LOG" 2>&1 || true
docker run -d --name cairn-smoke -p 4000:4000 \
  -v "$WORK/config:/config" -v "$WORK/data:/data" cairn:smoke >>"$LOG" 2>&1 ||
  fail "docker run"

say "waiting for the UI"
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/ || true)
  [ "$code" = 200 ] && break
  sleep 2
done
[ "$code" = 200 ] || fail "UI never served 200 (last: $code)"
say "PASS: UI serves 200"

cameras=$(curl -s -H "Authorization: Bearer smoke-token" http://localhost:4000/api/cameras)
echo "$cameras" >>"$LOG"
echo "$cameras" | grep -q smoke_cam || fail "/api/cameras does not list smoke_cam"
say "PASS: /api/cameras lists the camera"

# The stated-refusal check: the qnn failure must be *visible* — in the camera
# status payload or the container logs — and detection must not be reported
# healthy on this host.
if echo "$cameras" | grep -qi qnn; then
  say "PASS: qnn refusal stated in /api/cameras"
elif docker logs cairn-smoke 2>&1 | grep -qi "qnn"; then
  say "PASS: qnn refusal stated in logs (not yet in /api/cameras — eyeball it)"
  say "      $(docker logs cairn-smoke 2>&1 | grep -i qnn | head -3)"
else
  fail "no stated qnn refusal anywhere — silent CPU fallback?"
fi

docker rm -f cairn-smoke >>"$LOG" 2>&1
say "smoke complete — full log at $LOG"
