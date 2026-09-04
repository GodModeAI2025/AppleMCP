#!/usr/bin/env bash
# Builds the release artifact: M3MCP.app as a ZIP, plus its SHA256 checksum.
#
#   script/package_release.sh <output-directory>
#
# Runs offline and without GitHub. The release workflow calls this script and does nothing else, so
# whatever a release contains can be produced and inspected on a laptop before a tag exists.
#
# Packaging the same binaries twice produces a byte-identical ZIP: no build timestamp, no random
# staging name, fixed modification times in UTC, a fixed entry order, and an ad-hoc signature (see
# below). script/check_release_artifact.sh compares two runs in CI, so anything nondeterministic
# added here fails before a tag is set.
#
# What that does not claim: swift build itself is not bit-for-bit reproducible. Two clean release
# builds of the same commit with the same toolchain differ, measured here in 746 bytes of M3MCPApp
# with different LC_UUIDs. So the SHA256 next to the ZIP tells a downloader that the file arrived
# intact, not that the binary can be reproduced from source.
#
# What goes in:
#   M3MCP.app/Contents/MacOS/M3MCPApp      the SwiftUI app that holds the macOS privacy grants
#   M3MCP.app/Contents/MacOS/M3MCPBridge   the stdio MCP bridge an MCP client launches
#   M3MCP.app/Contents/Info.plist          with the version from CHANGELOG.md written in
#
# The bridge ships inside the bundle on purpose. Without it the download is unusable: an MCP client
# needs the bridge binary, and someone who takes the ZIP has no checkout to point at.
#
# Signing: ad hoc by default, or with the identity in M3MCP_CODESIGN_IDENTITY, the same variable
# and the same rules script/install_local.sh uses (script/lib/codesign.sh). There is no Developer ID
# and no notarisation here, so macOS warns on first launch either way.
#
# Ad hoc is the default rather than "whatever certificate is in the keychain" for two reasons. A
# release artifact goes to strangers, and picking up a personal Apple Development certificate would
# put a name and a team identifier into it by accident. And a certificate signature is not
# reproducible: two signings of the same file a few seconds apart differ inside the CMS blob,
# because codesign records the signing time there. An ad-hoc signature carries no CMS and comes out
# byte-identical.
set -euo pipefail

# UTC and a fixed umask, because zip stores local modification times and permission bits. Without
# these two lines the same input produces different archives in a different timezone.
export TZ=UTC
umask 022

APP_NAME="M3MCPApp"
BRIDGE_NAME="M3MCPBridge"
BUNDLE_NAME="M3MCP"
ZIP_NAME="M3MCP.app.zip"
CONFIGURATION="release"
# Any fixed date after 1980 works; the ZIP format cannot store anything earlier.
FIXED_TIMESTAMP="202001010000.00"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/codesign.sh
source "$ROOT_DIR/script/lib/codesign.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-directory>" >&2
  exit 2
fi

OUT_DIR="$1"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

VERSION="$("$ROOT_DIR/script/version.sh")"
echo "Version $VERSION (from CHANGELOG.md)"

# --- build ------------------------------------------------------------------------------------

echo "Building ($CONFIGURATION)…"
cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
for binary in "$APP_NAME" "$BRIDGE_NAME"; do
  [[ -x "$BIN_PATH/$binary" ]] || { echo "Build produced no $binary at $BIN_PATH" >&2; exit 1; }
done

# --- assemble ---------------------------------------------------------------------------------

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_BUNDLE="$STAGE_DIR/$BUNDLE_NAME.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BIN_PATH/$BRIDGE_NAME" "$APP_BUNDLE/Contents/MacOS/$BRIDGE_NAME"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$BRIDGE_NAME"
cp "$ROOT_DIR/Sources/$APP_NAME/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod 644 "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
chmod 644 "$APP_BUNDLE/Contents/PkgInfo"

# The version is written here rather than kept in the source Info.plist, so CHANGELOG.md stays the
# only place it is maintained. PlistBuddy's Add fails if the key is already there, which is the
# point: putting a version into the source plist would create a second copy to keep in step, and
# this step would stop rather than let the two drift apart.
#
# Package.swift also embeds the source Info.plist into the executable with -sectcreate; that copy
# carries no version. macOS reads Contents/Info.plist for a bundled app, which is this one.
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
                        -c "Add :CFBundleVersion string $VERSION" \
                        "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# Extended attributes would end up in the archive and can also make codesign refuse to sign.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# --- sign -------------------------------------------------------------------------------------

if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$(m3mcp_pick_identity)"
  SIGNATURE_KIND="certificate"
  echo "Signing identity: $IDENTITY"
  echo "Note: a certificate signature records a signing time, so this ZIP will not be byte-identical" >&2
  echo "to the next run. Leave M3MCP_CODESIGN_IDENTITY unset for a reproducible artifact." >&2
else
  IDENTITY="-"
  SIGNATURE_KIND="ad hoc"
  echo "Signing ad hoc (no M3MCP_CODESIGN_IDENTITY set)."
  echo "What that costs the user: the designated requirement is the binary hash, so the Full Disk"
  echo "Access grant has to be given again after every update. Gatekeeper warns in either case."
fi

# --timestamp=none: no network, and no signing time in the signature, which is what lets two runs
# produce identical bytes. Nested binaries first, then the bundle, so the bundle seal covers them.
codesign --force --timestamp=none --sign "$IDENTITY" "$APP_BUNDLE/Contents/MacOS/$BRIDGE_NAME" >/dev/null
codesign --force --timestamp=none --sign "$IDENTITY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null
codesign --force --timestamp=none --sign "$IDENTITY" "$APP_BUNDLE" >/dev/null
codesign --verify --strict --deep "$APP_BUNDLE"

if [[ "$SIGNATURE_KIND" == "certificate" ]]; then
  m3mcp_reject_revoked_signature "$APP_BUNDLE" "$IDENTITY"
fi

# --- archive ----------------------------------------------------------------------------------

# One fixed modification time for every entry. Signatures cover file contents, not mtimes, so this
# is safe to do after signing.
find "$APP_BUNDLE" -exec touch -t "${FIXED_TIMESTAMP%.*}" {} +

cd "$STAGE_DIR"
# -X drops the extra attribute fields (uid, gid, high-resolution times) that differ between machines.
# The sorted file list fixes the entry order, which find alone does not guarantee.
find "$BUNDLE_NAME.app" | LC_ALL=C sort | zip -X -q -@ "$STAGE_DIR/$ZIP_NAME"

mv -f "$STAGE_DIR/$ZIP_NAME" "$OUT_DIR/$ZIP_NAME"
cd "$OUT_DIR"
# Only the basename goes into the checksum file, so `shasum -a 256 -c M3MCP.app.zip.sha256` works
# in whatever directory the user downloaded it to.
shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"

echo
echo "Wrote $OUT_DIR/$ZIP_NAME"
echo "      $OUT_DIR/$ZIP_NAME.sha256"
echo
echo "  version:   $VERSION"
echo "  signature: $SIGNATURE_KIND"
echo "  sha256:    $(cut -d' ' -f1 < "$ZIP_NAME.sha256")"
echo "  size:      $(wc -c < "$ZIP_NAME" | tr -d ' ') bytes"
