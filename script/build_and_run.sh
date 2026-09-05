#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="M3MCPApp"
BRIDGE_NAME="M3MCPBridge"
BUNDLE_NAME="M3MCP"
BUNDLE_ID="de.markzimmermann.m3mcp"
MIN_SYSTEM_VERSION="15.0"
SIGN_IDENTITY=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
BRIDGE_BINARY="$APP_MACOS/$BRIDGE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/M3MCPApp/Resources/Info.plist"
source "$ROOT_DIR/script/signing_identity.sh"
# shellcheck source=lib/codesign.sh
source "$ROOT_DIR/script/lib/codesign.sh"

pick_identity() {
  # The verified listing supplies Apple-issued identities. The unfiltered listing is consulted only
  # for the exact intentionally self-signed local identity and its expected NOT_TRUSTED state.
  local valid all
  valid="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  all="$(security find-identity -p codesigning 2>/dev/null || true)"
  if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" ]]; then
    m3mcp_resolve_explicit_identity_from_listings "$M3MCP_CODESIGN_IDENTITY" "$valid" "$all"
    return
  fi
  m3mcp_pick_identity_from_listings "$valid" "$all" || true
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BIN_PATH="$(swift build --show-bin-path)"
BUILD_BINARY="$BIN_PATH/$APP_NAME"
BUILD_BRIDGE="$BIN_PATH/$BRIDGE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# The app pins the client it accepts to the M3MCPBridge next to its own executable. Without this
# copy every run of this script would be token-only, and the app window would say so.
cp "$BUILD_BRIDGE" "$BRIDGE_BINARY"
chmod +x "$BRIDGE_BINARY"
cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"
/usr/bin/xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true

SIGN_IDENTITY="$(pick_identity)"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with identity: $SIGN_IDENTITY"
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
else
  echo "Signing ad-hoc. Install a stable code-signing identity to preserve macOS privacy grants across rebuilds." >&2
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

if [[ -n "$SIGN_IDENTITY" ]]; then
  m3mcp_reject_expired_or_revoked_signature "$APP_BUNDLE" "$SIGN_IDENTITY"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
