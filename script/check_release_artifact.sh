#!/usr/bin/env bash
# Checks the artifact script/package_release.sh produced.
#
#   script/check_release_artifact.sh <output-directory>
#
# CI runs this on every push, so a broken package fails before anyone sets a tag rather than after.
# The release workflow runs it again on the tagged build.
#
# What it checks:
#   1. the ZIP exists and is not empty, and the .sha256 file next to it verifies
#   2. the entry list is exactly the expected one, so nothing from the repository can slip in:
#      no .git, no .github, no index.html, no sources, no keys, no example data
#   3. the unpacked bundle passes codesign --verify --strict --deep
#   4. the app and the bridge are there, executable, and Mach-O
#   5. the version inside Info.plist is the one CHANGELOG.md names
#   6. packaging the same binaries again produces the same bytes, so nothing in the packaging step
#      depends on the clock, the staging directory or the order the filesystem returns names
#
# Check 6 is about packaging, not about the compiler. swift build is not bit-for-bit reproducible,
# so a clean rebuild of the same commit gives a different binary and a different ZIP. It is skipped
# when M3MCP_CODESIGN_IDENTITY is set, because codesign records a signing time in the CMS blob and a
# certificate signature therefore cannot be byte-identical between two runs.
set -euo pipefail

ZIP_NAME="M3MCP.app.zip"
BUNDLE="M3MCP.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-directory>" >&2
  exit 2
fi

OUT_DIR="$(cd "$1" && pwd)"
ZIP="$OUT_DIR/$ZIP_NAME"
VERSION="$("$ROOT_DIR/script/version.sh")"

problems=0
fail() { echo "  FAIL  $*" >&2; problems=$((problems + 1)); }
pass() { echo "  ok    $*"; }

# Everything the archive is allowed to contain. An allowlist rather than a list of forbidden names,
# because the next thing that must not ship is the one nobody thought to forbid.
EXPECTED_ENTRIES="$(cat <<EOF
$BUNDLE/
$BUNDLE/Contents/
$BUNDLE/Contents/Info.plist
$BUNDLE/Contents/MacOS/
$BUNDLE/Contents/MacOS/M3MCPApp
$BUNDLE/Contents/MacOS/M3MCPBridge
$BUNDLE/Contents/PkgInfo
$BUNDLE/Contents/_CodeSignature/
$BUNDLE/Contents/_CodeSignature/CodeResources
EOF
)"

# Named separately so a failure says which repository innard leaked, not just "unexpected entry".
FORBIDDEN='(^|/)\.git(/|$)|(^|/)\.github(/|$)|(^|/)index\.html$|(^|/)course\.html$|(^|/)README|(^|/)Sources/|(^|/)Tests/|(^|/)docs/|(^|/)script/|\.(pem|p12|key|cer|der|mobileprovision|p8)$|(^|/)\.env|(^|/)\.DS_Store$|(^|/)__MACOSX(/|$)'

echo "Checking $OUT_DIR (version $VERSION)"

# --- 1. the files themselves ------------------------------------------------------------------

if [[ ! -f "$ZIP" ]]; then
  echo "  FAIL  $ZIP does not exist" >&2
  exit 1
fi

SIZE="$(wc -c < "$ZIP" | tr -d ' ')"
if [[ "$SIZE" -lt 100000 ]]; then
  fail "$ZIP_NAME is $SIZE bytes, far too small to hold a built app"
else
  pass "$ZIP_NAME exists, $SIZE bytes"
fi

if [[ ! -f "$ZIP.sha256" ]]; then
  fail "$ZIP_NAME.sha256 is missing"
elif (cd "$OUT_DIR" && shasum -a 256 -c "$ZIP_NAME.sha256" >/dev/null 2>&1); then
  pass "$ZIP_NAME.sha256 verifies: $(cut -d' ' -f1 < "$ZIP.sha256")"
else
  fail "$ZIP_NAME.sha256 does not match the ZIP"
fi

# The checksum file must name the file, not a path, or verification breaks in the download folder.
if [[ -f "$ZIP.sha256" ]] && ! grep -qE "[[:space:]]\*?${ZIP_NAME}\$" "$ZIP.sha256"; then
  fail "$ZIP_NAME.sha256 does not end in the plain file name, so shasum -c fails elsewhere"
fi

# --- 2. contents ------------------------------------------------------------------------------

ACTUAL_ENTRIES="$(unzip -Z1 "$ZIP" | LC_ALL=C sort)"

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if printf '%s' "$entry" | grep -qE "$FORBIDDEN"; then
    fail "the archive contains a repository file that must never ship: $entry"
  fi
done <<< "$ACTUAL_ENTRIES"

ENTRY_DIFF="$(mktemp)"
if diff <(printf '%s\n' "$EXPECTED_ENTRIES" | LC_ALL=C sort) <(printf '%s\n' "$ACTUAL_ENTRIES") > "$ENTRY_DIFF" 2>&1; then
  pass "archive contains exactly the expected $(printf '%s\n' "$ACTUAL_ENTRIES" | grep -c .) entries"
else
  fail "the archive does not contain what it should. '<' expected, '>' found:"
  sed 's/^/        /' "$ENTRY_DIFF" >&2
fi
rm -f "$ENTRY_DIFF"

# --- 3-5. the unpacked bundle -------------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
(cd "$WORK_DIR" && unzip -q "$ZIP")
APP="$WORK_DIR/$BUNDLE"

if codesign --verify --strict --deep "$APP" 2>/dev/null; then
  pass "codesign --verify --strict --deep passes: $(codesign -dv "$APP" 2>&1 | grep -E '^Signature' || echo 'signature unreadable')"
else
  fail "the unpacked bundle fails codesign --verify --strict --deep"
fi

for binary in M3MCPApp M3MCPBridge; do
  path="$APP/Contents/MacOS/$binary"
  if [[ ! -x "$path" ]]; then
    fail "$binary is missing or not executable"
  elif ! file "$path" | grep -q "Mach-O"; then
    fail "$binary is not a Mach-O executable"
  else
    pass "$binary is executable, $(wc -c < "$path" | tr -d ' ') bytes, $(lipo -archs "$path" 2>/dev/null || echo 'arch unknown')"
  fi
done

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }

BUNDLE_VERSION="$(plist_value CFBundleShortVersionString)"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  fail "Info.plist says CFBundleShortVersionString $BUNDLE_VERSION, CHANGELOG.md says $VERSION"
else
  pass "Info.plist carries the version from CHANGELOG.md: $VERSION"
fi

BUNDLE_ID="$(plist_value CFBundleIdentifier)"
if [[ "$BUNDLE_ID" != "de.markzimmermann.m3mcp" ]]; then
  fail "Info.plist has bundle identifier '$BUNDLE_ID'; the privacy grants are pinned to de.markzimmermann.m3mcp"
else
  pass "bundle identifier is $BUNDLE_ID"
fi

# --- 6. same binaries, same bytes ---------------------------------------------------------------

if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" ]]; then
  echo "  skip  reproducibility: M3MCP_CODESIGN_IDENTITY is set, and a certificate signature records"
  echo "        a signing time, so two runs cannot be byte-identical"
else
  REPEAT_DIR="$WORK_DIR/repeat"
  "$ROOT_DIR/script/package_release.sh" "$REPEAT_DIR" >/dev/null 2>&1
  if cmp -s "$ZIP" "$REPEAT_DIR/$ZIP_NAME"; then
    pass "packaging the same binaries again produces the same bytes"
  else
    fail "a second packaging run produced a different ZIP, so the artifact is not reproducible"
    fail "  first:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    fail "  second: $(shasum -a 256 "$REPEAT_DIR/$ZIP_NAME" | cut -d' ' -f1)"
  fi
fi

echo
if [[ "$problems" -gt 0 ]]; then
  echo "$problems problem(s) with the release artifact." >&2
  exit 1
fi
echo "Release artifact is in order."
