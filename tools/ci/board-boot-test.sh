#!/usr/bin/env bash
# board-boot-test.sh: boots the prod release with the fixture board attached
# from a board directory, and checks what only a release shows — embedded
# loading, an application the release ships winning over the directory's
# copy, the board application starting inside :cairn's start — plus what a
# refused boot prints.
#
# Builds the release (MIX_ENV=prod mix release) unless REL names a built
# one, and the fixture board through build-fixture-board.sh (CARGO is passed
# on). CI's board-loader job, and runnable locally; writes only under WORK
# (default: a fresh temporary directory), _build and cargo's cache. The
# release needs no assets: no request is made.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=${WORK:-$(mktemp -d)}
rel=${REL:-}
# Absolute, because the boot runs from inside $work.
mkdir -p "$work"
work=$(cd "$work" && pwd)
if [ -n "$rel" ]; then rel=$(cd "$rel" && pwd); fi
log=$work/boot-test.log
: >"$log"

say() { echo "[board-boot] $*" | tee -a "$log"; }
fail() {
  say "FAIL: $*"
  tail -40 "$log"
  # A daemon's own output is run_erl's, not the log's.
  for f in "$work"/tmp/log/erlang.log.*; do [ -f "$f" ] && tail -40 "$f"; done
  exit 1
}

if [ -z "$rel" ]; then
  say "building the prod release"
  (cd "$root" && MIX_ENV=prod mix release --overwrite) >>"$log" 2>&1 || fail "release build (see $log)"
  rel=$root/_build/prod/rel/cairn
fi

say "building the fixture board"
"$root/tools/ci/build-fixture-board.sh" "$work/board" >>"$log" 2>&1 || fail "fixture build (see $log)"
contract=$(sed -n 's/^{contract, \([0-9]*\)}\.$/\1/p' "$work/board/board.manifest")

# A reused WORK holds the last run's copies, and `cp -R` would nest into them.
rm -rf "$work"/board-{contract,shadow,shipped,nonif,noprofiles}

# Wrong contract: the same directory, the manifest one number off.
cp -R "$work/board" "$work/board-contract"
sed -i "s/^{contract, .*/{contract, $((contract + 1))}./" "$work/board-contract/board.manifest"

# Shadowing: the directory also carries cairn_stage, which the release
# ships; and a manifest naming that application as the board's.
cp -R "$work/board" "$work/board-shadow"
cp -R "$root/_build/fixture_board/prod/lib/cairn_stage" "$work/board-shadow/lib/cairn_stage-0.1.0"
cp -R "$work/board-shadow" "$work/board-shipped"
sed -i "s/^{app, .*/{app, cairn_stage}./" "$work/board-shipped/board.manifest"

# A board NIF missing from priv, and a board that fails conformance.
cp -R "$work/board" "$work/board-nonif"
rm "$work/board-nonif"/lib/*/priv/native/libcairn_fixture_board.so
cp -R "$work/board" "$work/board-noprofiles"
rm -r "$work/board-noprofiles"/lib/*/priv/profiles

# The fixture profile's model path is relative to the node's working
# directory, which is this one.
mkdir -p "$work/run/models" "$work/data" "$work/tmp"
: >"$work/run/models/fixture.fake"
cat >"$work/cairn.yml" <<'EOF'
plugins:
  det:
    profile: fixture-fake
    allow_experimental: true
EOF

export LC_ALL=${LC_ALL:-C.UTF-8}
export CAIRN_CONFIG=$work/cairn.yml CAIRN_DATA_DIR=$work/data RELEASE_TMP=$work/tmp
export PORT=${PORT:-4097} RELEASE_NODE=cairn_board_boot RELEASE_COOKIE=board-boot-test
export ERL_CRASH_DUMP=$work/tmp/erl_crash.dump
unset PHX_SERVER
cd "$work/run"
cairn() { "$rel/bin/cairn" "$@"; }

# Expression → its inspected value, through a node that is running.
rpc() { cairn rpc "IO.puts(inspect(($1), limit: :infinity, printable_limit: :infinity))"; }
expect() { # name expression expected
  got=$(rpc "$2" 2>&1) || fail "$1: rpc failed: $got"
  [ "$got" = "$3" ] || fail "$1: got $got, want $3"
  say "PASS: $1: $got"
}

# A refused boot: foreground start, which must exit non-zero, log `want`
# as the board's error and halt with OTP's slogan carrying it. The output is
# kept in the log.
refused() { # name board-dir want
  set +e
  out=$(CAIRN_BOARD_DIR=$2 timeout 120 "$rel/bin/cairn" start 2>&1)
  rc=$?
  set -e
  printf '%s\n' "--- $1 (exit $rc) ---" "$out" >>"$log"
  [ "$rc" != 0 ] && [ "$rc" != 124 ] || fail "$1: exit $rc"
  grep -qF -- "returned an error: {:board, \"" <<<"$out" || fail "$1: no board error logged"
  grep -qF -- "$3" <<<"$out" || fail "$1: output lacks: $3"
  grep -qF -- 'Kernel pid terminated (application_controller) ("{application_start_failure,cairn,{{board,' \
    <<<"$out" || fail "$1: no application_start_failure slogan"
  say "PASS: $1 (exit $rc): $(grep -F -m1 -- "$3" <<<"$out" | cut -c1-300)"
}

stop() { cairn stop >>"$log" 2>&1 || true; }
# `stop` returns once the stop is requested; a start under the same sname
# before the node is gone would be refused for the name.
gone() { for _ in $(seq 1 30); do cairn pid >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }
trap stop EXIT

say "booting with CAIRN_BOARD_DIR=$work/board-shadow"
CAIRN_BOARD_DIR=$work/board-shadow cairn daemon
for _ in $(seq 1 60); do
  up=$(rpc 'Application.started_applications() |> List.keymember?(:cairn, 0)' 2>/dev/null || true)
  [ "$up" = true ] && break
  sleep 1
done
[ "$up" = true ] || fail "node never reported :cairn started (see $log)"

expect "code mode" ':code.get_mode()' ':embedded'
expect "board" 'Cairn.Board.module()' 'Cairn.FixtureBoard.Board'
expect "board application, permanent" \
  ':application.info()[:started] |> List.keyfind(:cairn_fixture_board, 0)' \
  '{:cairn_fixture_board, :permanent}'
expect "board priv from the directory" \
  ':code.priv_dir(:cairn_fixture_board) |> to_string() |> String.starts_with?(System.get_env("CAIRN_BOARD_DIR"))' \
  'true'
expect "board NIF loaded from it" 'Cairn.FixtureBoard.Native.contract()' "$contract"
expect "cairn_stage is the release's copy" \
  ':code.lib_dir(:cairn_stage) |> to_string() |> String.starts_with?(System.get_env("RELEASE_ROOT") <> "/lib/")' \
  'true'
expect "the config names the fixture's profile" \
  'c = Cairn.Config.Server.get(); {c.profiles |> Map.keys() |> Enum.sort(), Enum.map(c.plugin_groups, &{&1.name, &1.profile.name})}' \
  '{["fixture-fake", "generic-ort"], [{"det", "fixture-fake"}]}'
expect "the booted drain holds the board's libraries" ':sys.get_state(Cairn.Native.Drain).libraries' \
  '[Cairn.FixtureBoard.Native, CairnOrt, Cairn.Native]'
stop
gone || fail "node still up 30 s after stop"
trap - EXIT

got=$(CAIRN_BOARD_DIR=$work/board cairn eval 'IO.inspect({Cairn.Board.module(), :code.get_mode()})' 2>&1) ||
  fail "eval: $got"
[ "$got" = "{Cairn.FixtureBoard.Board, :interactive}" ] || fail "eval: got $got"
say "PASS: bin/cairn eval sees the board: $got"

refused "wrong contract" "$work/board-contract" \
  "was built for contract $((contract + 1)); this release has contract $contract"
refused "missing directory" "$work/no-such-board" "board directory $work/no-such-board does not exist"
refused "board application the release ships" "$work/board-shipped" \
  "application cairn_stage in $work/board-shipped is already shipped by this release"

refused "board NIF missing" "$work/board-nonif" \
  "application cairn_fixture_board: module Cairn.FixtureBoard.Native failed its on_load"
refused "board that does not conform" "$work/board-noprofiles" \
  "board Cairn.FixtureBoard.Board in $work/board-noprofiles does not conform: Cairn.FixtureBoard.Board.profiles_dir/0 "

say "all passed; log: $log"
