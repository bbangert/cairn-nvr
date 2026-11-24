#!/usr/bin/env bash
# build-fixture-board.sh <out-dir> [contract]
#
# Builds test/fixture_board and its stub NIF, and assembles them as a board
# directory: <out-dir>/board.manifest and lib/<app>-<vsn>/{ebin,priv}.
# `contract` defaults to `Cairn.Stage.contract/0` as the source spells it;
# the boot test passes another to see it refused. Needs core's deps fetched
# (the fixture builds from them) and cargo; CARGO overrides the command,
# e.g. CARGO="cargo +1.100.0".
set -euo pipefail

[ $# -ge 1 ] || {
  echo "usage: $0 <out-dir> [contract]" >&2
  exit 2
}

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
contract=${2:-$(sed -n 's/^  def contract, do: \([0-9][0-9]*\)$/\1/p' "$root/libs/cairn_stage/lib/cairn/stage.ex")}
[ -n "$contract" ] || {
  echo "build-fixture-board: no contract number in libs/cairn_stage/lib/cairn/stage.ex" >&2
  exit 1
}

fixture=$root/test/fixture_board
build=$root/_build/fixture_board
cargo=${CARGO:-cargo}

CARGO_TARGET_DIR=$build/target $cargo build --release --locked \
  --manifest-path "$fixture/native/cairn_fixture_board/Cargo.toml"

# prod, like the release it attaches to, whatever MIX_ENV the caller has;
# the build path is the fixture's own either way.
(cd "$fixture" && MIX_ENV=prod mix compile --warnings-as-errors)

ebin=$build/prod/lib/cairn_fixture_board/ebin
vsn=$(sed -n 's/.*{vsn,"\([^"]*\)"}.*/\1/p' "$ebin/cairn_fixture_board.app")
lib=$out/lib/cairn_fixture_board-$vsn

rm -rf "$out"
mkdir -p "$lib/priv/native"
cp -R "$ebin" "$lib/ebin"
cp -R "$fixture/priv/profiles" "$lib/priv/profiles"
cp "$build/target/release/libcairn_fixture_board.so" "$lib/priv/native/"

cat >"$out/board.manifest" <<EOF
{app, cairn_fixture_board}.
{board, 'Elixir.Cairn.FixtureBoard.Board'}.
{contract, $contract}.
EOF

echo "build-fixture-board: $out (contract $contract, vsn $vsn)"
