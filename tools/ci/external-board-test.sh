#!/usr/bin/env bash
# external-board-test.sh: builds test/fixture_board the way a board in
# another repository would, against this checkout's HEAD through git alone,
# and boots the prod release with it attached.
#
# The fixture is taken out of the tree (`git archive`) and given a mix.exs of
# its own: own deps, build and lock, `cairn_stage` as a sparse git dependency
# at HEAD, the lock seeded from core's so it resolves the versions the release
# ships. A scratch crate takes `cairn-detect` and `cairn-ort` by git at the
# same rev; its lock must hold one copy of each, from one source, and a
# counter-case spelling the ref two ways must hold two, which shows the check
# sees what it is for. Only the lock is resolved: building `cairn-ort` needs
# FFmpeg 7 and an ONNX Runtime download, and the property is the resolution.
#
# Git dependencies, and the fixture's copy, see only committed content:
# uncommitted changes under libs/, plugins/ or test/fixture_board are not
# tested. Hex packages and the crates.io index and crates are fetched
# from the network; no git host is. CI's external-board job, and runnable
# locally. Builds the release (MIX_ENV=prod mix release) unless REL names a
# built one; CARGO overrides the command, e.g. CARGO="cargo +1.100.0". Writes
# only under WORK (default: a fresh temporary directory), cargo's and hex's
# caches, and _build when it builds the release.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
work=${WORK:-$(mktemp -d)}
rel=${REL:-}
cargo=${CARGO:-cargo}
mkdir -p "$work"
work=$(cd "$work" && pwd)
if [ -n "$rel" ]; then rel=$(cd "$rel" && pwd); fi
log=$work/external-board.log
: >"$log"

say() { echo "[external-board] $*" | tee -a "$log"; }
fail() {
  say "FAIL: $*"
  tail -40 "$log"
  for f in "$work"/tmp/log/erlang.log.*; do [ -f "$f" ] && tail -40 "$f"; done
  exit 1
}

url=file://$root
sha=$(git -C "$root" rev-parse HEAD)
dirty=$(git -C "$root" status --porcelain -- libs/cairn_stage plugins test/fixture_board)
[ -z "$dirty" ] || say "note: uncommitted changes are not seen; testing $sha"

if [ -z "$rel" ]; then
  say "building the prod release"
  (cd "$root" && MIX_ENV=prod mix release --overwrite) >>"$log" 2>&1 || fail "release build (see $log)"
  rel=$root/_build/prod/rel/cairn
fi
rel_vsn=$(cut -d' ' -f2 "$rel/releases/start_erl.data")

ext=$work/ext
rm -rf "$ext" "$work/board"
mkdir -p "$ext/board"

say "resolving cairn-detect and cairn-ort by git at $sha"
# name<TAB>source for every package in a Cargo.lock.
packages() { awk -F' = ' '/^\[\[package\]\]/ { n = ""; s = "" }
  $1 == "name" { n = $2 } $1 == "source" { s = $2; gsub(/"/, "", n); gsub(/"/, "", s); print n "\t" s }' "$1"; }
crate() { # dir cairn-detect-ref cairn-ort-ref
  mkdir -p "$1"
  : >"$1/lib.rs"
  cat >"$1/Cargo.toml" <<EOF
[package]
name = "external-board-crate"
version = "0.0.0"
edition = "2021"
publish = false

[lib]
path = "lib.rs"

[dependencies]
cairn-detect = { git = "$url", $2 }
cairn-ort = { git = "$url", $3, default-features = false }
EOF
  $cargo generate-lockfile --manifest-path "$1/Cargo.toml" >>"$log" 2>&1 || fail "cargo resolve in $1 (see $log)"
}
crate "$ext/crate" "rev = \"$sha\"" "rev = \"$sha\""
git_pkgs=$(packages "$ext/crate/Cargo.lock" | grep $'\tgit+' || true)
sources=$(cut -f2 <<<"$git_pkgs" | sort -u)
[ "$sources" = "git+$url?rev=$sha#$sha" ] || fail "git sources in the lock: $sources"
for c in cairn-detect cairn-ort; do
  n=$(grep -c "^$c"$'\t' <<<"$git_pkgs" || true)
  [ "$n" = 1 ] || fail "$n copies of $c in the lock"
done
dup=$(cut -f1 <<<"$git_pkgs" | sort | uniq -d)
[ -z "$dup" ] || fail "core crates locked twice: $dup"
say "PASS: one source, one copy each of: $(cut -f1 <<<"$git_pkgs" | sort | paste -sd" ")"

crate "$ext/crate-split" "rev = \"$sha\"" "rev = \"${sha:0:12}\""
n=$(packages "$ext/crate-split/Cargo.lock" | grep -c $'^cairn-detect\tgit+' || true)
[ "$n" = 2 ] || fail "the counter-case (rev spelled two ways) locked $n cairn-detect, want 2"
say "PASS: counter-case, the ref spelled two ways: $n copies of cairn-detect"

say "building the fixture board out of the tree"
# The toolchain and MIX_HOME (where hex is) the checkout resolves: outside
# it a version manager's shims (mise's) resolve neither, and Mix would
# install hex afresh.
tool=$(cd "$root" && elixir -e '
  IO.puts(Path.dirname(System.find_executable("mix")) <> ":" <> Path.join(:code.root_dir(), "bin"))
  IO.puts(Mix.Utils.mix_home())') || fail "no Elixir toolchain in $root"
bin=${tool%%$'\n'*} MIX_HOME=${tool#*$'\n'}
export PATH=$bin:$PATH MIX_HOME
git -C "$root" archive HEAD:test/fixture_board | tar -x -C "$ext/board"
cp "$root/mix.lock" "$ext/board/mix.lock"
echo "$sha" >"$ext/board/CORE_REF"
# `depth: 1`: git refuses a full fetch from a shallow repository, which CI's
# checkout is, and a board needs none of core's history.
cat >"$ext/board/mix.exs" <<EOF
defmodule CairnFixtureBoard.MixProject do
  use Mix.Project

  @core_ref __DIR__ |> Path.join("CORE_REF") |> File.read!() |> String.trim()

  def project do
    [
      app: :cairn_fixture_board,
      version: "0.1.0",
      elixir: "~> 1.19",
      cairn_board: Cairn.FixtureBoard.Board,
      deps: [{:cairn_stage, git: "$url", ref: @core_ref, sparse: "libs/cairn_stage", depth: 1}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF
# Step by step: `set -e` does not reach into a subshell tested with `||`.
run() { "$@" >>"$log" 2>&1 || fail "$* (see $log)"; }
cd "$ext/board"
CARGO_TARGET_DIR=$ext/target run $cargo build --release --locked \
  --manifest-path native/cairn_fixture_board/Cargo.toml
mkdir -p priv/native
cp "$ext/target/release/libcairn_fixture_board.so" priv/native/
export MIX_ENV=prod
run mix deps.get
run mix compile --warnings-as-errors
run mix cairn_stage.board --core-rel "$rel/releases/$rel_vsn/cairn.rel" --out "$work/board"
grep -qF "\"cairn_stage\": {:git, \"$url\", \"$sha\"" "$ext/board/mix.lock" ||
  fail "mix.lock does not lock cairn_stage to $url at $sha"
say "PASS: cairn_stage locked from $url at $sha"
contract=$(sed -n 's/^{contract, \([0-9]*\)}\.$/\1/p' "$work/board/board.manifest")

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
export PORT=${PORT:-4098} RELEASE_NODE=cairn_external_board RELEASE_COOKIE=external-board-test
export ERL_CRASH_DUMP=$work/tmp/erl_crash.dump CAIRN_BOARD_DIR=$work/board
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

expect "board" 'Cairn.Board.module()' 'Cairn.FixtureBoard.Board'
expect "board priv from the directory" \
  ':code.priv_dir(:cairn_fixture_board) |> to_string() |> String.starts_with?(System.get_env("CAIRN_BOARD_DIR"))' \
  'true'
expect "board NIF loaded from it" 'Cairn.FixtureBoard.Native.contract()' "$contract"
expect "cairn_stage is the release's copy" \
  ':code.lib_dir(:cairn_stage) |> to_string() |> String.starts_with?(System.get_env("RELEASE_ROOT") <> "/lib/")' \
  'true'

say "all passed; log: $log"
