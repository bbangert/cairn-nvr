#!/usr/bin/env bash
# rockchip-board-test.sh: builds boards/cairn_rockchip alone, in its own Mix
# project, as a board directory checked against the prod release's cairn.rel,
# and boots that release with it attached, then attaches it in a
# `bin/cairn eval`. The release is core's, built with no board, as the
# Rockchip image's is.
#
# x86 is enough for what is checked: the real board NIF builds and loads
# here, since it opens librknnrt, MPP and librga only when an engine or a
# decoder is opened; their absence is a preflight refusal, not a load failure.
#
# Builds the release (MIX_ENV=prod mix release, CAIRN_BOARD unset) unless REL
# names a built one; CARGO overrides the command, e.g. CARGO="cargo +1.100.0".
# Needs core's deps fetched, cargo, and the FFmpeg 7.1 the crate links: its
# own config points at /opt/ffmpeg7, and FFMPEG_PKG_CONFIG_PATH plus
# RUSTFLAGS="" (no rpath) take a distro's instead. CI's rockchip-board job,
# and runnable locally; writes only under WORK (default: a fresh temporary
# directory), _build, the board's _build, deps, target and git-ignored
# priv/native, and cargo's and hex's caches.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=${WORK:-$(mktemp -d)}
rel=${REL:-}
cargo=${CARGO:-cargo}
mkdir -p "$work"
work=$(cd "$work" && pwd)
log=$work/rockchip-board.log
: >"$log"

say() { echo "[rockchip-board] $*" | tee -a "$log"; }
fail() {
  say "FAIL: $*"
  tail -40 "$log"
  for f in "$work"/tmp/log/erlang.log.*; do [ -f "$f" ] && tail -40 "$f"; done
  exit 1
}
# Step by step: `set -e` does not reach into a subshell tested with `||`.
run() { "$@" >>"$log" 2>&1 || fail "$* (see $log)"; }

if [ -n "$rel" ]; then
  [ -f "$rel/releases/start_erl.data" ] || fail "REL=$rel is not a built release"
  rel=$(cd "$rel" && pwd)
else
  say "building the prod release with no board"
  (cd "$root" && env -u CAIRN_BOARD MIX_ENV=prod mix release --overwrite) >>"$log" 2>&1 ||
    fail "release build (see $log)"
  rel=$root/_build/prod/rel/cairn
fi
rel_vsn=$(cut -d' ' -f2 "$rel/releases/start_erl.data")
if compgen -G "$rel/lib/cairn_rockchip-*" >/dev/null; then
  fail "$rel ships cairn_rockchip; the board must come from the directory"
fi

say "building the board NIF"
board=$root/boards/cairn_rockchip
crate=$board/native/cairn_rockchip
# From the crate's directory: cargo reads `.cargo/config.toml` from where it
# runs, not from the manifest's.
(cd "$crate" && run $cargo build --release --locked)
mkdir -p "$board/priv/native"
cp "$crate/target/release/libcairn_rockchip.so" "$board/priv/native/"

say "building the board directory from its own project"
cd "$board"
export MIX_ENV=prod
run mix deps.get
run mix compile --warnings-as-errors
run mix cairn_stage.board --core-rel "$rel/releases/$rel_vsn/cairn.rel" --out "$work/board"
unset MIX_ENV
manifest=$(cat "$work/board/board.manifest")
contract=$(sed -n 's/^{contract, \([0-9]*\)}\.$/\1/p' <<<"$manifest")
grep -qxF "{board, 'Elixir.Cairn.Rockchip.Board'}." <<<"$manifest" || fail "manifest: $manifest"
for f in priv/native/libcairn_rockchip.so priv/profiles/rk3566-tier1.yml; do
  compgen -G "$work/board/lib/cairn_rockchip-*/$f" >/dev/null || fail "the directory lacks $f"
done
say "PASS: board directory: $(ls "$work/board/lib" | paste -sd" "), contract $contract"

# The profile's paths resolve against the node's working directory, where
# the image has /app/models: the labels must be there for the config to load.
mkdir -p "$work/run/models" "$work/data" "$work/tmp"
cp "$root/models/coco.names" "$work/run/models/"
cat >"$work/cairn.yml" <<'EOF'
plugins:
  det:
    profile: rk3566-tier1
    allow_experimental: true
EOF

export LC_ALL=${LC_ALL:-C.UTF-8}
export CAIRN_CONFIG=$work/cairn.yml CAIRN_DATA_DIR=$work/data RELEASE_TMP=$work/tmp
export PORT=${PORT:-4099} RELEASE_NODE=cairn_rockchip_board RELEASE_COOKIE=rockchip-board-test
export ERL_CRASH_DUMP=$work/tmp/erl_crash.dump CAIRN_BOARD_DIR=$work/board
# The artifact store off: with it on, the boot would download librknnrt and
# the profile's two rungs, which nothing here can run.
export ELIXIR_ERL_OPTIONS="-cairn artifacts false"
unset PHX_SERVER
cd "$work/run"
cairn() { "$rel/bin/cairn" "$@"; }
rpc() { cairn rpc "IO.puts(inspect(($1), limit: :infinity, printable_limit: :infinity))"; }
expect() { # name expression expected
  got=$(rpc "$2" 2>&1) || fail "$1: rpc failed: $got"
  [ "$got" = "$3" ] || fail "$1: got $got, want $3"
  say "PASS: $1: $got"
}
stop() { cairn stop >>"$log" 2>&1 || true; }
trap stop EXIT

say "booting with CAIRN_BOARD_DIR=$CAIRN_BOARD_DIR"
cairn daemon
for _ in $(seq 1 60); do
  up=$(rpc 'Application.started_applications() |> List.keymember?(:cairn, 0)' 2>/dev/null || true)
  [ "$up" = true ] && break
  sleep 1
done
[ "$up" = true ] || fail "node never reported :cairn started (see $log)"

expect "code mode" ':code.get_mode()' ':embedded'
expect "board" 'Cairn.Board.module()' 'Cairn.Rockchip.Board'
expect "board application, permanent" \
  ':application.info()[:started] |> List.keyfind(:cairn_rockchip, 0)' \
  '{:cairn_rockchip, :permanent}'
expect "board priv from the directory" \
  ':code.priv_dir(:cairn_rockchip) |> to_string() |> String.starts_with?(System.get_env("CAIRN_BOARD_DIR"))' \
  'true'
expect "board NIF loaded from it" '{Cairn.Rockchip.Native.load_error(), Cairn.Rockchip.Native.contract()}' \
  "{nil, $contract}"
expect "the config runs rk3566-tier1" \
  'c = Cairn.Config.Server.get(); {Map.has_key?(c.profiles, "rk3566-tier1"), Enum.map(c.plugin_groups, &{&1.name, &1.profile.name})}' \
  '{true, [{"det", "rk3566-tier1"}]}'
expect "the booted drain holds the board's library" \
  'Cairn.Rockchip.Native in :sys.get_state(Cairn.Native.Drain).libraries' 'true'
stop
trap - EXIT

# The path tools/board-pipeline/rk-cell.sh takes on the board.
got=$(CAIRN_BOARD_DIR=$work/board cairn eval \
  'IO.inspect({Cairn.Board.module(), Cairn.Rockchip.Native.load_error(), Cairn.Rockchip.Native.contract()})' 2>&1) ||
  fail "eval: $got"
[ "$got" = "{Cairn.Rockchip.Board, nil, $contract}" ] || fail "eval: got $got"
say "PASS: bin/cairn eval attaches the board, NIF loaded: $got"

say "all passed; log: $log"
