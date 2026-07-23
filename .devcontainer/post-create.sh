#!/usr/bin/env bash
# Devcontainer bootstrap: toolchain via mise (mise.toml), then app setup.
# The first run compiles Erlang from source — expect 10–20 minutes once;
# it's cached in the container image's home volume afterwards.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

mise trust --yes
mise install
eval "$(mise activate bash --shims)"

mix local.hex --force
mix local.rebar --force

# local runtime config (gitignored) — add your cameras here
if [ ! -f config.yml ]; then
  cp config.example.yml config.yml
fi

mix setup

echo
echo "Ready: 'mix phx.server' → http://localhost:4000  ·  'mix check' for the quality gate"
