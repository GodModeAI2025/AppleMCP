#!/usr/bin/env bash
# The release version and its changelog section.
#
# CHANGELOG.md supplies the release version used by the packaging workflow. The source plist and
# m3mcpVersion intentionally carry the same value because macOS and MCP clients consume those
# surfaces directly; script/check_docs.py and the artifact checker fail if those copies drift.
#
# The version is the first released heading below "## Unreleased". A heading may be plain
# ("## X.Y.Z") or carry a release date ("## X.Y.Z — YYYY-MM-DD"). Duplicate headings for the same
# version are rejected so release notes cannot silently select only part of a release.
#
# Usage:
#   script/version.sh              prints the version, e.g. 0.3.0
#   script/version.sh --section    prints the changelog entries for that version
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "No CHANGELOG.md at $CHANGELOG — the version has no source." >&2
  exit 1
fi

VERSION_HEADING="$(
  grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+([[:space:]]+—.*)?$' "$CHANGELOG" \
    || true
)"
VERSION="$(
  printf '%s\n' "$VERSION_HEADING" \
    | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
)"

if [[ -z "$VERSION" ]]; then
  echo "CHANGELOG.md has no released '## X.Y.Z' heading, so there is no version to read." >&2
  echo "Move the Unreleased entries under a version heading first." >&2
  exit 1
fi

VERSION_HEADING_COUNT="$(
  grep -E "^## ${VERSION}([[:space:]]+—.*)?$" "$CHANGELOG" \
    | wc -l \
    | tr -d ' ' \
    || true
)"
if [[ "$VERSION_HEADING_COUNT" != "1" ]]; then
  echo "CHANGELOG.md contains $VERSION_HEADING_COUNT headings for version $VERSION; expected exactly one." >&2
  exit 1
fi

case "${1:-}" in
  "")
    printf '%s\n' "$VERSION"
    ;;
  --section)
    # Everything between this version's dated or undated heading and the next "## " heading.
    SECTION="$(awk -v want="## $VERSION" '
      $0 == want || index($0, want " — ") == 1 { inside = 1; next }
      inside && /^## / { exit }
      inside { print }
    ' "$CHANGELOG" | sed -e '/./,$!d' | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }')"
    if [[ -z "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ]]; then
      echo "CHANGELOG.md has no release notes for version $VERSION." >&2
      exit 1
    fi
    printf '%s\n' "$SECTION"
    ;;
  *)
    echo "usage: $0 [--section]" >&2
    exit 2
    ;;
esac
