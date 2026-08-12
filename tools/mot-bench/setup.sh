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

# --- reference trackers (bytetrack_sweep.py) --------------------------------
# Tracker cores vendored at pinned SHAs, with mechanical patches from
# vendor-patches/ (provenance and patch rationale: vendor-patches/README.md).

vendor_tracker() {
  local name="$1" url="$2" sha="$3" subdir="$4"
  shift 4
  if [ -d "vendor/$name" ]; then
    echo "vendor/$name present — skipping (rm -rf to re-vendor)"
    return
  fi
  echo "Vendoring $name @ $sha"
  local tmp
  tmp="$(mktemp -d)"
  git clone --quiet "$url" "$tmp/repo"
  git -C "$tmp/repo" checkout --quiet "$sha"
  mkdir -p "vendor/$name"
  local f
  for f in "$@" LICENSE; do
    if [ "$f" = LICENSE ]; then
      cp "$tmp/repo/LICENSE" "vendor/$name/"
    else
      cp "$tmp/repo/$subdir/$f" "vendor/$name/"
    fi
  done
  rm -rf "$tmp"
  if [ -f "vendor-patches/$name.patch" ]; then
    patch -p1 -d "vendor/$name" < "vendor-patches/$name.patch"
  fi
  touch "vendor/$name/__init__.py"
}

vendor_tracker bytetrack https://github.com/ifzhang/ByteTrack \
  d1bf0191adff59bc8fcfeaa0b33d3d1642552a99 yolox/tracker \
  basetrack.py byte_tracker.py kalman_filter.py matching.py

vendor_tracker ocsort https://github.com/noahcao/OC_SORT \
  8462e7e729a93ccd3bd995c0a79a890336cb3a0b trackers/ocsort_tracker \
  association.py kalmanfilter.py ocsort.py

vendor_tracker sparsetrack https://github.com/hustvl/SparseTrack \
  499844f32c5bb2332f9811f26cd70cf4e517d4e7 tracker \
  basetrack.py kalman_filter.py matching.py sparse_tracker.py

echo "Setup complete."
