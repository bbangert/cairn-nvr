#!/usr/bin/env bash
# The fast dev loop: build the release HERE, push its bytecode into the
# running add-on container on the board, restart it. Seconds, not the
# 20-minute tag→CI→ghcr→pull cycle — that stays the distribution path.
# MIX_ENV=prod inside this script is the sanctioned release build (Ben,
# 2026-08-19); the plugin hook still guards ad-hoc prod commands.
#
# What rides: every app's ebin from the assembled release (deps included —
# pushing "just cairn" would miss a dep bump silently), cairn's priv —
# priv/profiles, priv/repo AND priv/static — plus runtime.exs, sys.config,
# env.sh (rel/env.sh.eex: pre-VM environment, e.g. malloc tuning) and the
# boot artifacts below. What cannot ride: NIFs/canary (arch-native),
# ERTS, apt packages, Dockerfile-level anything.
#
# priv/static used to be excluded so a dev build could not clobber the
# image's digested assets. Shipping the COMPLETE digested set answers that:
# `mix assets.deploy` below minifies and runs phx.digest, so the tar carries
# the digested files AND the cache_manifest.json naming them, from one build.
# Plug.Static serves what the manifest names, so the two cannot disagree.
# (The install is a merge, so digests from the image's own build stay on
# disk unreferenced — dead weight in a scratch container, not a hazard.)
# Without this the browser keeps running the image's OLD bundle after a
# push, which makes any JS/CSS change silently a no-op on the board.
#
# Boot artifacts ride too, and for a reason that cost a board outage: an
# embedded release boots from `start.boot`, which lists the modules of every
# application. A module the image's boot script never heard of does not
# exist to the node no matter how correct its .beam is — and protocol
# dispatch reads `releases/*/consolidated`, not the ebin copies. New module
# or new protocol impl means start.boot/start.script/cairn.rel/consolidated
# must land with the bytecode.
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

# Compile BEFORE the asset build, the Docker build's own order: both asset
# entry points import phoenix-colocated/cairn from the Mix build path, so an
# uncompiled prod build fails to resolve it and a stale one silently bundles
# old colocated hooks.
echo "[push] compiling (prod)"
MIX_ENV=prod mix compile >/dev/null

# Before the release, not as part of it: this project's `releases:` block has
# no `steps:` hook, so `mix release` assembles whatever is in priv/static and
# never digests. Release assembly then copies priv (a symlink into the source
# tree) into the release, so the order is what puts digested assets there.
echo "[push] building assets (minified + digested)"
MIX_ENV=prod mix assets.deploy >/dev/null

echo "[push] building release (prod)"
MIX_ENV=prod mix release --overwrite --quiet

REL=_build/prod/rel/cairn
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

(cd "$REL" && tar czf "$STAGE/push.tgz" \
  --exclude='*.so' --exclude='lib/cairn-*/priv/native' \
  lib/*/ebin lib/cairn-*/priv \
  releases/*/runtime.exs releases/*/sys.config releases/*/env.sh \
  releases/*/start.boot releases/*/start.script releases/*/cairn.rel releases/*/consolidated)

# POSIX sh — the container's shell is dash.
cat > "$STAGE/install.sh" <<'EOS'
set -e
cd /tmp
rm -rf push
mkdir push
cd push
tar xzf /tmp/push.tgz
# EVERY compatibility check runs before the FIRST copy: a refusal
# mid-install would leave /app a mixture of pushed and image code, which a
# later container crash would happily boot.
for d in lib/*/; do
  name=$(basename "$d")
  app=${name%-*}
  # The pushed start.boot names each app's VERSIONED ebin dir, so a locally
  # bumped app must be installed under the PUSH'S name — copying into the
  # image's old-version dir would leave the new boot pointing at directories
  # that were never created. A same-version push resolves to the same dir.
  if [ ! -d /app/lib/"$name" ]; then
    exists=""
    for target in /app/lib/"$app"-*; do
      [ -d "$target" ] && exists="$target"
    done
    # Fatal, not a warning: the release boot script cannot load an app the
    # image never shipped, so restarting would report success on a broken
    # node.
    if [ -z "$exists" ]; then
      echo "push: no installed dir for $name — a new dep needs a real image" >&2
      exit 1
    fi
    # A bumped app would ride only its BEAMs: its priv stays the image's,
    # and pairing new bytecode with an old priv is exactly how a NIF loader
    # meets the wrong .so ABI (exqlite-class deps) — and how non-native priv
    # resources go quietly stale. Refuse rather than guess.
    if [ -d "$exists"/priv ]; then
      echo "push: $name bumps an app whose priv lives in the image — needs a real image" >&2
      exit 1
    fi
  fi
done
# The release dir is part of the same preflight: its absence must refuse
# BEFORE any app ebin lands, not after all of them have.
release_target=""
for target in /app/releases/*/; do
  [ -d "$target" ] && release_target=1
done
if [ -z "$release_target" ]; then
  echo "push: the image has no release dir to receive runtime config" >&2
  exit 1
fi
# Preflight proved every app and the release dir installable; nothing below
# refuses.
for d in lib/*/; do
  name=$(basename "$d")
  mkdir -p /app/lib/"$name"
  cp -r "$d". /app/lib/"$name"/
done
# By existing dir, not by version — like the app loop above: a local
# version bump must not silently skip the config files while still
# stamping PUSH_OK.
#
# -r is load-bearing: `consolidated` is a directory, and plain cp refuses a
# directory with a non-zero status, which under `set -e` aborts the install.
for r in releases/*/; do
  for target in /app/releases/*/; do
    [ -d "$target" ] || continue
    cp -r "$r"* "$target"
  done
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
# :os.cmd returns output with no exit status and nerves_ssh exits 0 either
# way — the marker after the && chain is the success signal, checked here.
result=$(ssh "$BOARD" ":os.cmd(~c\"balena-engine cp /data/cairn-push.tgz $CONTAINER:/tmp/push.tgz && balena-engine cp /data/cairn-push-install.sh $CONTAINER:/tmp/install.sh && balena-engine exec $CONTAINER /bin/sh /tmp/install.sh && balena-engine restart $CONTAINER && echo PUSH_OK 2>&1\") |> List.to_string()")
echo "$result" | head -4
case "$result" in
*PUSH_OK*) echo "[push] done — container restarted with the new code" ;;
*)
  echo "[push] FAILED — the install chain did not complete:" >&2
  echo "$result" | tail -8 >&2
  exit 1
  ;;
esac
