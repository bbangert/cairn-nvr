#!/usr/bin/env bash
# Mirror deploy/vagus-addon/ to the public add-on repo (branch master —
# vagus's store fetcher defaults to ref "master"). First run: create the
# public repo once with `gh repo create bbangert/cairn-addons --public`.
# The ghcr image itself is pushed by .github/workflows/container.yml; its
# package must be flipped to public once — vagus pulls anonymously.
set -euo pipefail

REPO="${ADDON_REPO:-git@github.com:bbangert/cairn-addons.git}"
SRC="$(cd "$(dirname "$0")/../../deploy/vagus-addon" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 "$REPO" "$WORK/repo"
rsync -a --delete --exclude .git "$SRC"/ "$WORK/repo"/
cd "$WORK/repo"
if git diff --quiet && git diff --cached --quiet; then
  echo "add-on repo already up to date"
  exit 0
fi
version=$(sed -n 's/^version: "\(.*\)"/\1/p' cairn/config.yaml)
git add -A
git commit -m "cairn ${version}: sync from cairn-nvr deploy/vagus-addon"
git push origin HEAD:master
echo "published add-on repo at ${version}"
