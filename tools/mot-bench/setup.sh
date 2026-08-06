#!/usr/bin/env bash
# Sets up the Python environment and vendored TrackEval checkout for the MOT
# accuracy harness. Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TRACKEVAL_SHA="12c8791b303e0a0b50f753af204249e622d0281a"
TRACKEVAL_URL="https://github.com/JonathonLuiten/TrackEval"

if [ ! -d .venv ]; then
  echo "Creating .venv"
  python3 -m venv .venv
fi

echo "Installing Python dependencies"
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

if [ ! -d vendor/trackeval ]; then
  echo "Cloning TrackEval"
  mkdir -p vendor
  git clone "$TRACKEVAL_URL" vendor/trackeval
fi

echo "Checking out TrackEval @ $TRACKEVAL_SHA"
git -C vendor/trackeval checkout "$TRACKEVAL_SHA"

echo "Setup complete."
