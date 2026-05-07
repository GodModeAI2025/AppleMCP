#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="M3MCPApp"
BUNDLE_NAME="M3MCP"
BUNDLE_ID="de.markzimmermann.m3mcp"
MIN_SYSTEM_VERSION="15.0"
SIGN_IDENTITY="${M3MCP_CODESIGN_IDENTITY:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/M3MCPApp/Resources/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"
/usr/bin/xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null | /usr/bin/awk -F '"' '/M3MCP Local Development|Apple Development|Developer ID Application/ { print $2; exit }')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with identity: $SIGN_IDENTITY"
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
else
  echo "Signing ad-hoc. Install a stable code-signing identity to preserve macOS privacy grants across rebuilds." >&2
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

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
