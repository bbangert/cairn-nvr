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
#      must say so, never silently run CPU;
#   5. a second boot on the same /data honours the import marker: the YAML
#      cameras were imported into the database exactly once, the camera is
#      still served from the rows, and the file's cameras: key earns the
#      "remove the key" warning rather than a re-import.
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
# The container writes into the /data bind mount as root (soak samples, logs)
# once it lives long enough, and an unprivileged runner's rm then fails —
# which, inside an EXIT trap, becomes the whole script's exit code and fails a
# smoke that passed. Best-effort only; CI runners are ephemeral.
trap 'docker rm -f cairn-smoke >/dev/null 2>&1 || true; rm -rf "$WORK" 2>/dev/null || true' EXIT
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

# Through a LAN-looking Host header too: prod once shipped force_ssl with a
# localhost-only exclusion, so every non-localhost request 301'd at an https
# listener that doesn't exist — invisible to a localhost-only smoke.
lan_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: 192.0.2.10:4000" http://localhost:4000/ || true)
[ "$lan_code" = 200 ] || fail "UI answered $lan_code for a LAN host header (force_ssl regression?)"
say "PASS: UI serves 200 for a non-localhost host"

# And the LiveView transport from that same LAN identity: check_origin
# once compared against the configured host (localhost), so the page
# rendered and then its socket retried the mount forever. The verdict is
# in the longpoll JSON envelope, never the HTTP code — Phoenix answers 200
# either way, {"status":403} rejected vs {"status":410} for a fresh
# session (device-measured on 0.1.1/0.1.2).
lp_body=$(curl -s -H "Host: 192.0.2.10:4000" -H "Origin: http://192.0.2.10:4000" \
  "http://localhost:4000/live/longpoll?vsn=2.0.0" || true)
case "$lp_body" in
*'"status":410'*) say "PASS: LiveView transport accepts the LAN origin" ;;
*) fail "LiveView longpoll envelope for a LAN origin: $lp_body (check_origin regression?)" ;;
esac

cameras=$(curl -s -H "Authorization: Bearer smoke-token" http://localhost:4000/api/cameras)
echo "$cameras" >>"$LOG"
echo "$cameras" | grep -q smoke_cam || fail "/api/cameras does not list smoke_cam"
say "PASS: /api/cameras lists the camera"

# The stated-refusal check: failure vocabulary, not the word "qnn" — a
# healthy payload also says qnn (plugin_status.backend), so matching the
# name alone would pass on exactly the silent success this exists to catch.
# Polled like every other check here: a fast boot can reach this before the
# docker log driver has flushed the canary line the app already emitted —
# one run failed the single-shot grep while fail()'s own dump, milliseconds
# later, showed the line.
refused=""
for _ in $(seq 1 10); do
  if docker logs cairn-smoke 2>&1 |
    grep -Eqi "canary refused|model was NOT loaded|Failed to load library"; then
    refused=yes
    break
  fi
  sleep 1
done

if [ "$refused" = yes ]; then
  say "PASS: qnn refusal stated in logs"
  say "      $(docker logs cairn-smoke 2>&1 | grep -Ei "canary refused|Failed to load library" | head -2)"
else
  fail "no stated qnn refusal — silent CPU fallback?"
fi

# Second boot, same /data (so the same cairn.db): the marker written on the
# first boot must stop a re-import — a loader that imported again would
# either duplicate the fleet or, on the id collision, refuse the load, and
# both read as "cameras present" to every check above. `docker logs` spans
# both boots, so the import line is counted, not just matched.
say "restarting the container for the second-boot import check"
docker restart cairn-smoke >>"$LOG" 2>&1 || fail "docker restart"

for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/ || true)
  [ "$code" = 200 ] && break
  sleep 2
done
[ "$code" = 200 ] || fail "UI never served 200 after the restart (last: $code)"

cameras=$(curl -s -H "Authorization: Bearer smoke-token" http://localhost:4000/api/cameras)
echo "$cameras" >>"$LOG"
echo "$cameras" | grep -q smoke_cam || fail "/api/cameras does not list smoke_cam after the second boot"

imports=$(docker logs cairn-smoke 2>&1 | grep -c "imported 1 camera(s) from" || true)
[ "$imports" = 1 ] || fail "expected exactly one import across two boots, saw $imports"
docker logs cairn-smoke 2>&1 | grep -q "cameras changed since they were imported" &&
  fail "the second boot read the unchanged YAML cameras as drift"
docker logs cairn-smoke 2>&1 | grep -q "still lists cameras:" ||
  fail "the second boot did not warn that config.yml still lists cameras"
say "PASS: second boot honours the import marker (one import, rows served, remove-the-key warning)"

docker rm -f cairn-smoke >>"$LOG" 2>&1
say "smoke complete — full log at $LOG"
