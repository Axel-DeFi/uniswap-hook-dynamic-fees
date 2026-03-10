#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/release/cut.sh [--bump patch|minor|major] [--push] [--dry-run]

Options:
  --bump      SemVer increment kind (default: patch)
  --push      Push commit and tag to origin.
  --dry-run   Print computed version and exit without changes.
  -h, --help  Show this message.
USAGE
}

semver_re='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
bump_kind="patch"
do_push="0"
dry_run="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump)
      shift
      if [[ $# -eq 0 ]]; then
        echo "ERROR: --bump requires value patch|minor|major." >&2
        exit 1
      fi
      bump_kind="$1"
      ;;
    --push)
      do_push="1"
      ;;
    --dry-run)
      dry_run="1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument '$1'." >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "${bump_kind}" != "patch" && "${bump_kind}" != "minor" && "${bump_kind}" != "major" ]]; then
  echo "ERROR: --bump must be patch|minor|major, got '${bump_kind}'." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: Working tree is not clean. Commit/stash changes first." >&2
  exit 1
fi

git fetch --tags origin

latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1 || true)"
if [[ -z "${latest_tag}" ]]; then
  echo "ERROR: No SemVer tags found (expected at least one vX.Y.Z tag)." >&2
  exit 1
fi

latest_version="${latest_tag#v}"
if [[ ! "${latest_version}" =~ ${semver_re} ]]; then
  echo "ERROR: Latest tag '${latest_tag}' is not valid SemVer." >&2
  exit 1
fi

if [[ ! -f VERSION ]]; then
  echo "${latest_version}" > VERSION
fi

current_version="$(tr -d '[:space:]' < VERSION)"
if [[ ! "${current_version}" =~ ${semver_re} ]]; then
  echo "ERROR: VERSION must be SemVer X.Y.Z, got '${current_version}'." >&2
  exit 1
fi

if [[ "${current_version}" != "${latest_version}" ]]; then
  echo "ERROR: VERSION (${current_version}) must match latest tag (${latest_tag}) before cutting a new release." >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "${bump_kind}" in
  patch)
    patch=$((patch + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
esac

new_version="${major}.${minor}.${patch}"
new_tag="v${new_version}"

if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
  echo "ERROR: Tag ${new_tag} already exists locally." >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/${new_tag}" | grep -q "${new_tag}$"; then
  echo "ERROR: Tag ${new_tag} already exists on origin." >&2
  exit 1
fi

today="$(date +%Y-%m-%d)"
release_header="## ${new_tag} - ${today}"

if [[ "${dry_run}" == "1" ]]; then
  echo "latest:  ${latest_tag}"
  echo "current: v${current_version}"
  echo "next:    ${new_tag}"
  exit 0
fi

echo "${new_version}" > VERSION

if ! grep -Eq "^## ${new_tag} - " CHANGELOG.md; then
  tmp_changelog="$(mktemp)"
  {
    echo "# CHANGELOG"
    echo
    echo "${release_header}"
    echo
    echo "### Release summary"
    echo "- Release notes captured in git history and audit bundle updates."
    echo
    sed '1d' CHANGELOG.md
  } > "${tmp_changelog}"
  mv "${tmp_changelog}" CHANGELOG.md
fi

git add VERSION CHANGELOG.md
git commit -m "release: ${new_tag}"
git tag -a "${new_tag}" -m "${new_tag}"

./scripts/release/check.sh

if [[ "${do_push}" == "1" ]]; then
  git push origin HEAD
  git push origin "refs/tags/${new_tag}"
fi

echo "Release created: ${new_tag}"
