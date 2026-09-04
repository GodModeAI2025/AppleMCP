#!/usr/bin/env bash
# Validates the release candidate produced by script/package_release.sh.
#
# This checker is intended for a candidate built from the repository under review. It validates the
# archive before extraction and executes the packaged bridge only after the exact entry/type/size,
# checksum, signature, metadata, and license gates pass.
set -euo pipefail

ZIP_NAME="M3MCP.app.zip"
BUNDLE="M3MCP.app"
MAXIMUM_ZIP_BYTES=268435456
MAXIMUM_UNPACKED_BYTES=536870912
MAXIMUM_BRIDGE_OUTPUT_BYTES=20971520

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PLIST="$ROOT_DIR/Sources/M3MCPApp/Resources/Info.plist"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-directory>" >&2
  exit 2
fi
if [[ ! -d "$1" ]]; then
  echo "Release output directory does not exist: $1" >&2
  exit 1
fi

OUT_DIR="$(cd "$1" && pwd)"
ZIP="$OUT_DIR/$ZIP_NAME"
VERSION="$("$ROOT_DIR/script/version.sh")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_PLIST")"

problems=0
fail() { echo "  FAIL  $*" >&2; problems=$((problems + 1)); }
pass() { echo "  ok    $*"; }

EXPECTED_ENTRIES="$(cat <<EOF
$BUNDLE/
$BUNDLE/Contents/
$BUNDLE/Contents/Info.plist
$BUNDLE/Contents/MacOS/
$BUNDLE/Contents/MacOS/M3MCPApp
$BUNDLE/Contents/MacOS/M3MCPBridge
$BUNDLE/Contents/PkgInfo
$BUNDLE/Contents/Resources/
$BUNDLE/Contents/Resources/LICENSE
$BUNDLE/Contents/Resources/THIRD_PARTY.md
$BUNDLE/Contents/_CodeSignature/
$BUNDLE/Contents/_CodeSignature/CodeResources
EOF
)"

EXPECTED_DEFAULT_TOOLS="$(cat <<'EOF'
source_status
permissions_status
calendar_search
calendar_read_event
calendar_list_calendars
contacts_search
mail_search
mail_list_mailboxes
mail_read
reminders_search
notes_search
notes_read
photos_search
photos_albums
voicememos_search
voicememos_read
voicememos_transcript
voicememos_audio
voicememos_transcribe
ai_summarize
ai_image_playground
EOF
)"

EXPECTED_OPTIONAL_TOOLS="$(cat <<'EOF'
permissions_request
permissions_open_settings
calendar_create_event
calendar_update_event
calendar_delete_event
calendar_create_calendar
calendar_delete_calendar
ai_writing_tools
ai_translate
EOF
)"
EXPECTED_ALL_TOOLS="$(printf '%s\n%s\n' "$EXPECTED_DEFAULT_TOOLS" "$EXPECTED_OPTIONAL_TOOLS")"

FORBIDDEN='(^|/)\.git(/|$)|(^|/)\.github(/|$)|(^|/)index\.html$|(^|/)course\.html$|(^|/)README|(^|/)Sources/|(^|/)Tests/|(^|/)docs/|(^|/)script/|\.(pem|p12|key|cer|der|mobileprovision|p8)$|(^|/)\.env|(^|/)\.DS_Store$|(^|/)__MACOSX(/|$)'

echo "Checking $OUT_DIR (version $VERSION, build $SOURCE_BUILD)"

# --- archive envelope -------------------------------------------------------------------------

if [[ ! -f "$ZIP" ]]; then
  echo "  FAIL  $ZIP does not exist" >&2
  exit 1
fi

SIZE="$(wc -c < "$ZIP" | tr -d ' ')"
if [[ ! "$SIZE" =~ ^[0-9]+$ || "$SIZE" -lt 100000 ]]; then
  fail "$ZIP_NAME is ${SIZE:-unknown} bytes, too small to hold a built app"
elif [[ "$SIZE" -gt "$MAXIMUM_ZIP_BYTES" ]]; then
  fail "$ZIP_NAME is $SIZE bytes, above the $MAXIMUM_ZIP_BYTES-byte archive ceiling"
else
  pass "$ZIP_NAME exists, $SIZE bytes"
fi

if [[ ! -f "$ZIP.sha256" ]]; then
  fail "$ZIP_NAME.sha256 is missing"
elif [[ "$(wc -l < "$ZIP.sha256" | tr -d ' ')" != "1" ]] \
  || ! grep -qE "^[[:xdigit:]]{64}[[:space:]][ *]${ZIP_NAME}$" "$ZIP.sha256"; then
  fail "$ZIP_NAME.sha256 must contain exactly one digest for the plain archive filename"
elif (cd "$OUT_DIR" && shasum -a 256 -c "$ZIP_NAME.sha256" >/dev/null 2>&1); then
  pass "$ZIP_NAME.sha256 verifies: $(cut -d' ' -f1 < "$ZIP.sha256")"
else
  fail "$ZIP_NAME.sha256 does not match the ZIP"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- exact entry, type, and expansion policy ---------------------------------------------------

if ACTUAL_ENTRIES="$(unzip -Z1 "$ZIP" 2>/dev/null | LC_ALL=C sort)"; then
  ENTRY_COUNT="$(printf '%s\n' "$ACTUAL_ENTRIES" | grep -c . || true)"
else
  fail "cannot list ZIP entries"
  ENTRY_COUNT=0
  ACTUAL_ENTRIES=""
fi

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if printf '%s' "$entry" | grep -qE "$FORBIDDEN"; then
    fail "archive contains a repository or credential-shaped file: $entry"
  fi
done <<< "$ACTUAL_ENTRIES"

ENTRY_DIFF="$WORK_DIR/entry.diff"
if diff \
  <(printf '%s\n' "$EXPECTED_ENTRIES" | LC_ALL=C sort) \
  <(printf '%s\n' "$ACTUAL_ENTRIES") \
  > "$ENTRY_DIFF" 2>&1; then
  pass "archive contains exactly the expected $ENTRY_COUNT entries"
else
  fail "archive entry allowlist mismatch; '<' expected, '>' found:"
  sed 's/^/        /' "$ENTRY_DIFF" >&2
fi

if ZIP_TYPES="$(zipinfo -l "$ZIP" 2>/dev/null | awk '$NF ~ /^M3MCP\.app\// { print substr($1, 1, 1) " " $NF }')"; then
  while IFS=' ' read -r entry_type entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == */ ]]; then
      [[ "$entry_type" == "d" ]] || fail "archive directory has non-directory type '$entry_type': $entry"
    else
      [[ "$entry_type" == "-" ]] || fail "archive file has non-regular type '$entry_type': $entry"
    fi
  done <<< "$ZIP_TYPES"
else
  fail "cannot inspect ZIP entry types"
fi

UNPACKED_SIZE="$(unzip -l "$ZIP" 2>/dev/null | awk '/files?$/ { value=$1 } END { print value }')"
if [[ ! "$UNPACKED_SIZE" =~ ^[0-9]+$ ]]; then
  fail "cannot determine the archive's uncompressed size"
elif [[ "$UNPACKED_SIZE" -gt "$MAXIMUM_UNPACKED_BYTES" ]]; then
  fail "archive expands to $UNPACKED_SIZE bytes, above the $MAXIMUM_UNPACKED_BYTES-byte ceiling"
else
  pass "archive expands to $UNPACKED_SIZE bytes within the configured ceiling"
fi

if [[ "$problems" -eq 0 ]]; then
  if unzip -tqq "$ZIP" >/dev/null 2>&1; then
    pass "ZIP structure and compressed data test cleanly"
  else
    fail "ZIP structure or compressed data is invalid"
  fi
fi

if [[ "$problems" -gt 0 ]]; then
  echo "$problems archive-envelope problem(s); refusing to extract or execute the candidate." >&2
  exit 1
fi

(cd "$WORK_DIR" && unzip -q "$ZIP")
APP="$WORK_DIR/$BUNDLE"
if [[ -n "$(find "$APP" -type l -print -quit)" ]]; then
  fail "unpacked bundle contains a symbolic link"
fi

# --- signature, metadata, binaries, and retained notices --------------------------------------

if codesign --verify --strict --deep "$APP" 2>/dev/null; then
  pass "codesign --verify --strict --deep passes"
else
  fail "unpacked bundle fails codesign --verify --strict --deep"
fi

SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if [[ -z "${M3MCP_CODESIGN_IDENTITY:-}" || "${M3MCP_CODESIGN_IDENTITY:-}" == "-" ]]; then
  if printf '%s\n' "$SIGNATURE_DETAILS" | grep -q '^Signature=adhoc$'; then
    pass "default candidate is explicitly ad-hoc signed"
  else
    fail "default candidate does not report Signature=adhoc"
  fi
else
  EXPECTED_CERTIFICATE_FINGERPRINT="$(
    printf '%s' "$M3MCP_CODESIGN_IDENTITY" | tr '[:lower:]' '[:upper:]'
  )"
  if [[ ! "$EXPECTED_CERTIFICATE_FINGERPRINT" =~ ^[[:xdigit:]]{40}$ ]]; then
    fail "certificate verification requires M3MCP_CODESIGN_IDENTITY to be a 40-hex fingerprint"
  elif printf '%s\n' "$SIGNATURE_DETAILS" | grep -q '^Signature=adhoc$'; then
    fail "certificate mode received an ad-hoc-signed bundle"
  else
    CERTIFICATE_PREFIX="$WORK_DIR/signing-certificate"
    if codesign -d --extract-certificates "$CERTIFICATE_PREFIX" "$APP" >/dev/null 2>&1 \
      && [[ -f "${CERTIFICATE_PREFIX}0" ]]; then
      ACTUAL_CERTIFICATE_FINGERPRINT="$(
        shasum -a 1 "${CERTIFICATE_PREFIX}0" \
          | cut -d' ' -f1 \
          | tr '[:lower:]' '[:upper:]'
      )"
      if [[ "$ACTUAL_CERTIFICATE_FINGERPRINT" == "$EXPECTED_CERTIFICATE_FINGERPRINT" ]]; then
        pass "bundle leaf certificate matches the requested fingerprint"
      else
        fail "bundle leaf certificate $ACTUAL_CERTIFICATE_FINGERPRINT differs from requested $EXPECTED_CERTIFICATE_FINGERPRINT"
      fi
    else
      fail "certificate mode could not extract a leaf signing certificate"
    fi
  fi
fi

for binary in M3MCPApp M3MCPBridge; do
  path="$APP/Contents/MacOS/$binary"
  if [[ ! -f "$path" || -L "$path" || ! -x "$path" ]]; then
    fail "$binary is missing, linked, non-regular, or not executable"
    continue
  fi
  if ! file "$path" | grep -q "Mach-O"; then
    fail "$binary is not a Mach-O executable"
    continue
  fi
  ARCHITECTURES="$(lipo -archs "$path" 2>/dev/null || true)"
  if [[ "$ARCHITECTURES" != "arm64" ]]; then
    fail "$binary architectures are '${ARCHITECTURES:-unknown}'; candidate policy requires exactly arm64"
  else
    pass "$binary is an arm64 Mach-O executable, $(wc -c < "$path" | tr -d ' ') bytes"
  fi
  MINIMUM_OS="$(otool -l "$path" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build_version = 1; next }
    build_version && $1 == "minos" { print $2; exit }
  ')"
  if [[ "$MINIMUM_OS" != "15.0" ]]; then
    fail "$binary minimum macOS is '${MINIMUM_OS:-unknown}'; expected 15.0"
  else
    pass "$binary deployment target is macOS $MINIMUM_OS"
  fi
done

if cmp -s "$SOURCE_PLIST" "$APP/Contents/Info.plist"; then
  pass "packaged Info.plist is byte-identical to the reviewed source plist"
else
  fail "packaged Info.plist differs from the reviewed source plist"
fi

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
BUNDLE_VERSION="$(plist_value CFBundleShortVersionString)"
BUNDLE_BUILD="$(plist_value CFBundleVersion)"
BUNDLE_ID="$(plist_value CFBundleIdentifier)"
BUNDLE_MINIMUM_OS="$(plist_value LSMinimumSystemVersion)"

[[ "$BUNDLE_VERSION" == "$VERSION" ]] \
  && pass "Info.plist release version is $VERSION" \
  || fail "Info.plist version '$BUNDLE_VERSION' differs from release version $VERSION"
[[ "$BUNDLE_BUILD" == "$SOURCE_BUILD" ]] \
  && pass "Info.plist build number is $SOURCE_BUILD" \
  || fail "Info.plist build '$BUNDLE_BUILD' differs from source build $SOURCE_BUILD"
[[ "$BUNDLE_ID" == "de.markzimmermann.m3mcp" ]] \
  && pass "bundle identifier is $BUNDLE_ID" \
  || fail "bundle identifier '$BUNDLE_ID' differs from de.markzimmermann.m3mcp"
[[ "$BUNDLE_MINIMUM_OS" == "15.0" ]] \
  && pass "bundle deployment target is macOS $BUNDLE_MINIMUM_OS" \
  || fail "bundle deployment target '${BUNDLE_MINIMUM_OS:-missing}' differs from 15.0"

if [[ "$(< "$APP/Contents/PkgInfo")" == "APPL????" ]]; then
  pass "PkgInfo has the expected application signature"
else
  fail "PkgInfo content differs from APPL????"
fi
if cmp -s "$ROOT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"; then
  pass "Apache-2.0 license is retained byte-for-byte"
else
  fail "Apache-2.0 license is missing or changed"
fi
if cmp -s "$ROOT_DIR/docs/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"; then
  pass "third-party notices are retained byte-for-byte"
else
  fail "third-party notices are missing or changed"
fi

# --- bounded packaged MCP lifecycle and catalog checks ----------------------------------------

if [[ "$problems" -gt 0 ]]; then
  echo "$problems signature/metadata problem(s); refusing to execute the candidate bridge." >&2
  exit 1
fi

run_catalog_check() {
  local label="$1"
  local expected_tools="$2"
  local input="$WORK_DIR/$label.input.jsonl"
  local output="$WORK_DIR/$label.output.jsonl"
  local init_reply="$WORK_DIR/$label.initialize.json"
  local tools_reply="$WORK_DIR/$label.tools.json"
  local actual_names="$WORK_DIR/$label.names"
  local expected_names="$WORK_DIR/$label.expected"
  local catalog_diff="$WORK_DIR/$label.diff"
  local bridge="$APP/Contents/MacOS/M3MCPBridge"
  local pid attempt output_size response_lines tool_count index name unique_count response_id bridge_version
  local bridge_output_blocks=$((MAXIMUM_BRIDGE_OUTPUT_BYTES / 512))

  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check_release_artifact","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    > "$input"
  : > "$output"

  if [[ "$label" == "default" ]]; then
    (
      ulimit -f "$bridge_output_blocks"
      exec env \
        M3MCP_ENABLE_CALENDAR_MUTATIONS=0 \
        M3MCP_ENABLE_PERMISSION_UI=0 \
        M3MCP_ENABLE_USER_SHORTCUTS=0 \
        "$bridge"
    ) < "$input" > "$output" 2>/dev/null &
  else
    (
      ulimit -f "$bridge_output_blocks"
      exec env \
        M3MCP_ENABLE_CALENDAR_MUTATIONS=1 \
        M3MCP_ENABLE_PERMISSION_UI=1 \
        M3MCP_ENABLE_USER_SHORTCUTS=1 \
        "$bridge"
    ) < "$input" > "$output" 2>/dev/null &
  fi
  pid=$!

  output_size=0
  response_lines=0
  for ((attempt = 1; attempt <= 50; attempt++)); do
    output_size="$(wc -c < "$output" 2>/dev/null | tr -d ' ' || true)"
    response_lines="$(wc -l < "$output" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$output_size" =~ ^[0-9]+$ && "$output_size" -gt "$MAXIMUM_BRIDGE_OUTPUT_BYTES" ]]; then
      break
    fi
    if [[ "$response_lines" =~ ^[0-9]+$ && "$response_lines" -ge 2 ]]; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt = 1; attempt <= 10; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true

  output_size="$(wc -c < "$output" 2>/dev/null | tr -d ' ' || true)"
  response_lines="$(wc -l < "$output" 2>/dev/null | tr -d ' ' || true)"
  if [[ ! "$output_size" =~ ^[0-9]+$ || "$output_size" -gt "$MAXIMUM_BRIDGE_OUTPUT_BYTES" ]]; then
    fail "$label bridge output exceeded the $MAXIMUM_BRIDGE_OUTPUT_BYTES-byte checker ceiling"
    return 1
  fi
  if [[ "$response_lines" != "2" ]]; then
    fail "$label bridge lifecycle produced ${response_lines:-unknown} response lines; expected exactly 2 within 5 seconds"
    return 1
  fi

  sed -n '1p' "$output" > "$init_reply"
  sed -n '2p' "$output" > "$tools_reply"
  response_id="$(/usr/bin/plutil -extract id raw -o - "$init_reply" 2>/dev/null || true)"
  bridge_version="$(/usr/bin/plutil -extract result.serverInfo.version raw -o - "$init_reply" 2>/dev/null || true)"
  if [[ "$response_id" != "1" || "$bridge_version" != "$VERSION" ]]; then
    fail "$label initialize reply id/version is '${response_id:-missing}/${bridge_version:-missing}', expected 1/$VERSION"
    return 1
  fi

  response_id="$(/usr/bin/plutil -extract id raw -o - "$tools_reply" 2>/dev/null || true)"
  tool_count="$(/usr/bin/plutil -extract result.tools raw -o - "$tools_reply" 2>/dev/null || true)"
  if [[ "$response_id" != "2" || ! "$tool_count" =~ ^[0-9]+$ ]]; then
    fail "$label tools/list reply is not a structurally valid id=2 tool array"
    return 1
  fi

  : > "$actual_names"
  for ((index = 0; index < tool_count; index++)); do
    name="$(/usr/bin/plutil -extract "result.tools.$index.name" raw -o - "$tools_reply" 2>/dev/null || true)"
    if [[ -z "$name" ]]; then
      fail "$label tool entry $index has no parseable name"
      return 1
    fi
    printf '%s\n' "$name" >> "$actual_names"
  done

  unique_count="$(LC_ALL=C sort -u "$actual_names" | grep -c . || true)"
  if [[ "$unique_count" != "$tool_count" ]]; then
    fail "$label catalog contains duplicate tool names ($tool_count entries, $unique_count unique)"
    return 1
  fi

  printf '%s\n' "$expected_tools" | LC_ALL=C sort > "$expected_names"
  LC_ALL=C sort "$actual_names" > "$actual_names.sorted"
  if diff "$expected_names" "$actual_names.sorted" > "$catalog_diff" 2>&1; then
    pass "$label MCP lifecycle reports the exact $tool_count-tool catalog"
  else
    fail "$label MCP catalog differs from the exact policy; '<' expected, '>' reported:"
    sed 's/^/        /' "$catalog_diff" >&2
    return 1
  fi
}

run_catalog_check default "$EXPECTED_DEFAULT_TOOLS" || true
run_catalog_check all-opt-ins "$EXPECTED_ALL_TOOLS" || true

# --- same binaries, same candidate bytes -------------------------------------------------------

if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" && "${M3MCP_CODESIGN_IDENTITY:-}" != "-" ]]; then
  echo "  skip  reproducibility: certificate signatures carry signing-time material"
else
  REPEAT_DIR="$WORK_DIR/repeat"
  if "$ROOT_DIR/script/package_release.sh" "$REPEAT_DIR" >/dev/null 2>&1 \
    && cmp -s "$ZIP" "$REPEAT_DIR/$ZIP_NAME"; then
    pass "packaging the same binaries again produces the same candidate bytes"
  else
    fail "a second packaging run did not produce the same ZIP bytes"
    if [[ -f "$REPEAT_DIR/$ZIP_NAME" ]]; then
      echo "        first:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)" >&2
      echo "        second: $(shasum -a 256 "$REPEAT_DIR/$ZIP_NAME" | cut -d' ' -f1)" >&2
    fi
  fi
fi

echo
if [[ "$problems" -gt 0 ]]; then
  echo "$problems problem(s) with the release candidate." >&2
  exit 1
fi
echo "Release candidate passes the local artifact policy. It remains ad-hoc and unnotarized unless a separate trusted signing pipeline is used."
