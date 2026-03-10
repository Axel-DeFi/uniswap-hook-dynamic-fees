#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f "VERSION" ]]; then
  echo "ERROR: VERSION file is missing." >&2
  exit 1
fi

if [[ ! -f "CHANGELOG.md" ]]; then
  echo "ERROR: CHANGELOG.md is missing." >&2
  exit 1
fi

version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: VERSION must be SemVer X.Y.Z, got '${version}'." >&2
  exit 1
fi

if ! grep -Eq "^## v${version} - " CHANGELOG.md; then
  echo "ERROR: CHANGELOG.md must contain heading '## v${version} - YYYY-MM-DD'." >&2
  exit 1
fi

git fetch --tags origin >/dev/null 2>&1 || true

if ! git rev-parse -q --verify "refs/tags/v${version}" >/dev/null; then
  echo "ERROR: Missing git tag v${version}." >&2
  exit 1
fi

latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1 || true)"
if [[ -z "${latest_tag}" ]]; then
  echo "ERROR: No SemVer tags found (expected format vX.Y.Z)." >&2
  exit 1
fi

if [[ "${latest_tag}" != "v${version}" ]]; then
  echo "ERROR: VERSION (${version}) does not match latest SemVer tag (${latest_tag})." >&2
  exit 1
fi

echo "Release version check passed: v${version}"
