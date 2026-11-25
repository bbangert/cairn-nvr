#!/usr/bin/env bash
# build-fixture-board.sh <out-dir> <core-rel>
#
# Builds test/fixture_board and its stub NIF, and writes them as a board
# directory with `mix cairn_stage.board`, checked against <core-rel>, the
# release's releases/<vsn>/cairn.rel. Needs core's deps fetched (the fixture
# builds from them) and cargo; CARGO overrides the command, e.g.
# CARGO="cargo +1.100.0".
set -euo pipefail

[ $# -eq 2 ] || {
  echo "usage: $0 <out-dir> <core-rel>" >&2
  exit 2
}

root=$(cd "$(dirname "$0")/../.." && pwd)
# Absolute, because the task runs from the fixture's project.
out=$(realpath -m "$1")
core_rel=$(realpath "$2")
fixture=$root/test/fixture_board
build=$root/_build/fixture_board
cargo=${CARGO:-cargo}

CARGO_TARGET_DIR=$build/target $cargo build --release --locked \
  --manifest-path "$fixture/native/cairn_fixture_board/Cargo.toml"
# Into the application's `priv`, which the task ships and `Native` loads
# from.
mkdir -p "$fixture/priv/native"
cp "$build/target/release/libcairn_fixture_board.so" "$fixture/priv/native/"

# prod, like the release it attaches to, whatever MIX_ENV the caller has;
# the build path is the fixture's own either way.
cd "$fixture"
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix cairn_stage.board --core-rel "$core_rel" --out "$out"
