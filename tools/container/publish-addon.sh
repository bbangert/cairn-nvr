#!/usr/bin/env bash
# Mirror repository.yaml and the named add-on directories of
# deploy/vagus-addon/ (default: cairn) to the public add-on repo (branch
# master — vagus's store fetcher defaults to ref "master"). An add-on reaches
# the public repo only when named here, so an unreleased one stays private;
# directories already published and not named are left as they are.
#   tools/container/publish-addon.sh [addon-dir ...]
# First run: create the public repo once with
# `gh repo create bbangert/cairn-addons --public`. The ghcr images are pushed
# by .github/workflows/container.yml; each package must be flipped to public
# once — vagus pulls anonymously.
set -euo pipefail

REPO="${ADDON_REPO:-git@github.com:bbangert/cairn-addons.git}"
SRC="$(cd "$(dirname "$0")/../../deploy/vagus-addon" && pwd)"
[ "$#" -gt 0 ] || set -- cairn

summary=()
for addon in "$@"; do
  case "$addon" in
  "" | . | .. | */*)
    echo "not an add-on directory name: '$addon'" >&2
    exit 1
    ;;
  esac
  if [ ! -f "$SRC/$addon/config.yaml" ]; then
    echo "$addon: no deploy/vagus-addon/$addon/config.yaml" >&2
    exit 1
  fi
  version=$(sed -n 's/^version: "\(.*\)"/\1/p' "$SRC/$addon/config.yaml")
  if [ -z "$version" ]; then
    echo "$addon: config.yaml has no quoted version:" >&2
    exit 1
  fi
  # The mirror copies the working tree, so anything uncommitted or ignored
  # in it (a config.yml with camera credentials, say) would be published.
  dirty=$(git -C "$SRC" status --porcelain --untracked-files=all --ignored -- "$addon")
  if [ -n "$dirty" ]; then
    echo "$addon: deploy/vagus-addon/$addon differs from HEAD; commit or remove:" >&2
    echo "$dirty" >&2
    exit 1
  fi
  summary+=("$addon $version")
done
dirty=$(git -C "$SRC" status --porcelain --untracked-files=all --ignored -- repository.yaml)
if [ -n "$dirty" ]; then
  echo "deploy/vagus-addon/repository.yaml differs from HEAD; commit or remove:" >&2
  echo "$dirty" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 "$REPO" "$WORK/repo"
cp "$SRC/repository.yaml" "$WORK/repo/repository.yaml"
for addon in "$@"; do
  # --delete scoped to this add-on's directory: stale files inside it go,
  # sibling add-ons are untouched.
  rsync -a --delete "$SRC/$addon"/ "$WORK/repo/$addon"/
done
cd "$WORK/repo"
# status --porcelain, not diff --quiet: the first publish into an empty
# repo (and any later new file) is all untracked additions, which diff
# does not see.
if [ -z "$(git status --porcelain)" ]; then
  echo "add-on repo already up to date"
  exit 0
fi
joined=$(printf '%s, ' "${summary[@]}")
joined=${joined%, }
git add -A
git commit -m "${joined}: sync from cairn-nvr deploy/vagus-addon"
git push origin HEAD:master
echo "published add-on repo: ${joined}"
