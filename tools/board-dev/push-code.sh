#!/usr/bin/env bash
# The fast dev loop: build the release HERE, push its bytecode into the
# running add-on container on the board, restart it. Seconds, not the
# 20-minute tag→CI→ghcr→pull cycle — that stays the distribution path.
# MIX_ENV=prod inside this script is the sanctioned release build (Ben,
# 2026-08-19); the plugin hook still guards ad-hoc prod commands.
#
# What rides: every app's ebin from the assembled release (deps included —
# pushing "just cairn" would miss a dep bump silently), cairn's
# priv/profiles + priv/repo, runtime.exs and sys.config. What cannot ride:
# NIFs/canary (arch-native), ERTS, priv/static (the image's digested assets
# must not be clobbered by a dev build), apt packages, Dockerfile-level
# anything.
#
# The installer maps lib/<app>-<vsn>/ → the EXISTING /app/lib/<app>-*/ dir:
# the release boot script pins exact versions, so a dep whose version
# changed must land in the directory the boot script actually loads.
#
# Scratch by definition: a vagus update recreates the container and erases
# pushed code, and anything that feeds a CLAIM (parity cells, soak,
# sign-off) runs on a released image.
#
# Usage: tools/board-dev/push-code.sh   (BOARD=… CONTAINER=… to override)
set -euo pipefail

BOARD=${BOARD:-192.168.2.87}
CONTAINER=${CONTAINER:-addon_c2da371c_cairn}

cd "$(dirname "$0")/../.."

echo "[push] building release (prod)"
MIX_ENV=prod mix release --overwrite --quiet

REL=_build/prod/rel/cairn
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

(cd "$REL" && tar czf "$STAGE/push.tgz" \
  --exclude='*.so' --exclude='lib/cairn-*/priv/static' --exclude='lib/cairn-*/priv/native' \
  lib/*/ebin lib/cairn-*/priv releases/*/runtime.exs releases/*/sys.config)

# POSIX sh — the container's shell is dash.
cat > "$STAGE/install.sh" <<'EOS'
set -e
cd /tmp
rm -rf push
mkdir push
cd push
tar xzf /tmp/push.tgz
for d in lib/*/; do
  name=$(basename "$d")
  app=${name%-*}
  installed=""
  for target in /app/lib/"$app"-*; do
    [ -d "$target" ] || continue
    cp -r "$d". "$target"/
    installed=1
  done
  [ -n "$installed" ] || echo "push: no installed dir for $name (new dep needs a real image)" >&2
done
for r in releases/*/; do
  ver=$(basename "$r")
  [ -d "/app/releases/$ver" ] && cp "$r"* "/app/releases/$ver/"
done
EOS

echo "[push] shipping to $BOARD"
# nerves_ssh's exec channel evaluates Elixir, not shell — transport rides the
# SFTP subsystem instead.
sftp -q "$BOARD" >/dev/null <<EOF
put $STAGE/push.tgz /data/cairn-push.tgz
put $STAGE/install.sh /data/cairn-push-install.sh
EOF

echo "[push] installing into $CONTAINER"
ssh "$BOARD" ":os.cmd(~c\"balena-engine cp /data/cairn-push.tgz $CONTAINER:/tmp/push.tgz && balena-engine cp /data/cairn-push-install.sh $CONTAINER:/tmp/install.sh && balena-engine exec $CONTAINER /bin/sh /tmp/install.sh && balena-engine restart $CONTAINER 2>&1\") |> List.to_string() |> String.slice(0, 400)" | head -4

echo "[push] done — container restarted with the new code"
