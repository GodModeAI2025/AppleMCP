#!/usr/bin/env bash
# Recreate the macOS icon from the checked-in full-resolution master.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT_DIR/assets/branding/localmcp-icon.png"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Sources/M3MCPApp/Resources/AppIcon.icns"
