#!/usr/bin/env bash
# The image compiles the release on the Dockerfile's ELIXIR_VERSION /
# OTP_VERSION; CI and local work install from mise.toml. Nothing else ties
# the two, and a suite that passed on another OTP says little about the
# release. Fails when they differ, or when the toolchain on PATH is not the
# pinned one.
set -euo pipefail
cd "$(dirname "$0")/../.."

arg() { sed -n "s/^ARG $1=//p" Dockerfile; }
tool() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" mise.toml; }

image_otp=$(arg OTP_VERSION)
image_elixir=$(arg ELIXIR_VERSION)
pin_otp=$(tool erlang)
pin_elixir=$(tool elixir)

rc=0
differ() {
  echo "toolchain: $1 is '$2', $3 is '$4'" >&2
  rc=1
}

[ -n "$image_otp" ] && [ -n "$image_elixir" ] && [ -n "$pin_otp" ] && [ -n "$pin_elixir" ] || {
  echo "toolchain: a version did not parse from Dockerfile or mise.toml" >&2
  exit 1
}

[ "$pin_otp" = "$image_otp" ] ||
  differ "mise.toml erlang" "$pin_otp" "Dockerfile OTP_VERSION" "$image_otp"
# mise names the Elixir build by the OTP major it was compiled for.
[ "$pin_elixir" = "$image_elixir-otp-${image_otp%%.*}" ] ||
  differ "mise.toml elixir" "$pin_elixir" "Dockerfile ELIXIR_VERSION on OTP ${image_otp%%.*}" "$image_elixir"

# otp_release is the major only; the full version is in this file.
run_otp=$(erl -noshell -eval '
  {ok, V} = file:read_file(filename:join([code:root_dir(), "releases",
    erlang:system_info(otp_release), "OTP_VERSION"])),
  io:put_chars(string:trim(V)), halt().')
run_elixir=$(elixir -e 'IO.write(System.version())')

[ "$run_otp" = "$image_otp" ] ||
  differ "OTP on PATH" "$run_otp" "Dockerfile OTP_VERSION" "$image_otp"
[ "$run_elixir" = "$image_elixir" ] ||
  differ "Elixir on PATH" "$run_elixir" "Dockerfile ELIXIR_VERSION" "$image_elixir"

[ "$rc" = 0 ] && echo "toolchain: OTP $run_otp, Elixir $run_elixir — image, mise.toml and PATH agree"
exit "$rc"
