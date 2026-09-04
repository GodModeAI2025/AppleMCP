#!/usr/bin/env bash
# The version of this project, and the changelog section that belongs to it.
#
# CHANGELOG.md is the single place the version is maintained. Nothing else in the repository
# carries a version number: script/package_release.sh writes it into the app bundle's Info.plist
# while packaging, and .github/workflows/release.yml compares it against the pushed tag. Adding a
# second copy anywhere would create the drift this script exists to prevent.
#
# The version is the first released heading in CHANGELOG.md, that is the first "## X.Y.Z" below the
# "## Unreleased" section. Releasing therefore means moving the Unreleased entries under a new
# heading, not editing a number somewhere else.
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

VERSION="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+$' "$CHANGELOG" | sed 's/^## //')"

if [[ -z "$VERSION" ]]; then
  echo "CHANGELOG.md has no released '## X.Y.Z' heading, so there is no version to read." >&2
  echo "Move the Unreleased entries under a version heading first." >&2
  exit 1
fi

case "${1:-}" in
  "")
    printf '%s\n' "$VERSION"
    ;;
  --section)
    # Everything between this version's heading and the next "## " heading.
    awk -v want="## $VERSION" '
      $0 == want { inside = 1; next }
      inside && /^## / { exit }
      inside { print }
    ' "$CHANGELOG" | sed -e '/./,$!d' | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }'
    ;;
  *)
    echo "usage: $0 [--section]" >&2
    exit 2
    ;;
esac
