#!/usr/bin/env bash
# Installs M3MCP as a login-time background service.
#
# Differences from build_and_run.sh, which is meant for one-off runs:
#
#  - Installs outside the repository. If the checkout lives in an iCloud-managed folder (Desktop or
#    Documents with "Desktop & Documents Folders" sync on), the file provider re-applies
#    com.apple.FinderInfo to the bundle within a second of `xattr -cr`, and codesign then refuses to
#    sign it. Staging under ~/Applications avoids that race entirely.
#
#  - Refuses expired or revoked certificates. build_and_run.sh picks the first identity matching
#    "Apple Development", which may be expired or revoked. Signing with a revoked certificate makes
#    macOS treat the app as malware and move it to the Bin — this script fails loudly instead.
#
#  - Runs the app from launchd rather than a shell. This matters for Full Disk Access: TCC evaluates
#    the *responsible* process, so an app started from a terminal inherits the terminal's grant
#    instead of using its own. Under launchd the app is its own responsible process, so the grant you
#    give this bundle is the grant that applies.
set -euo pipefail

APP_NAME="M3MCPApp"
BUNDLE_NAME="M3MCP"
BUNDLE_ID="de.markzimmermann.m3mcp"
CONFIGURATION="${M3MCP_CONFIGURATION:-release}"
INSTALL_DIR="${M3MCP_INSTALL_DIR:-$HOME/Applications}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/$APP_NAME/Resources/Info.plist"

# --- signing identity -------------------------------------------------------------------------

pick_identity() {
  if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$M3MCP_CODESIGN_IDENTITY"
    return
  fi
  # A self-signed local identity is preferred: it cannot expire out from under you mid-project and
  # gives a certificate-based designated requirement, so privacy grants survive rebuilds.
  #
  # Only expiry and revocation disqualify a certificate. CSSMERR_TP_NOT_TRUSTED is the normal state
  # for a self-signed certificate and codesign accepts it, so it must not be filtered out.
  local all
  all="$(security find-identity -p codesigning 2>/dev/null || true)"
  for name in "M3MCP Local Development" "Developer ID Application" "Apple Development"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if printf '%s' "$line" | grep -qE "CSSMERR_TP_CERT_(EXPIRED|REVOKED)"; then
        local reason
        reason="$(printf '%s' "$line" | sed 's/.*(\(CSSMERR[^)]*\)).*/\1/')"
        echo "Skipping unusable identity ($reason): $name" >&2
        continue
      fi
      printf '%s\n' "$line" | sed 's/.*"\(.*\)".*/\1/'
      return
    done < <(printf '%s\n' "$all" | grep -F "\"$name")
  done
}

IDENTITY="$(pick_identity)"
if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<EOF
No usable code-signing identity found.

Create a local one (recommended — keeps Full Disk Access working across rebuilds):
  ./script/create_local_identity.sh

Ad-hoc signing is deliberately not used here: its designated requirement contains the binary hash,
so every rebuild silently invalidates the app's Full Disk Access grant.
EOF
  exit 1
fi
echo "Signing identity: $IDENTITY"

# --- build ------------------------------------------------------------------------------------

echo "Building ($CONFIGURATION)…"
cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"
BUILT_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
[[ -x "$BUILT_BINARY" ]] || { echo "Build produced no binary at $BUILT_BINARY" >&2; exit 1; }

# --- stop the running instance ----------------------------------------------------------------

if [[ -f "$AGENT_PLIST" ]]; then
  launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
fi
pkill -x "$APP_NAME" 2>/dev/null || true

# --- assemble the bundle ----------------------------------------------------------------------

echo "Installing to $APP_BUNDLE"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILT_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$SOURCE_INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# --- sign -------------------------------------------------------------------------------------

codesign --force --sign "$IDENTITY" "$APP_BINARY" >/dev/null
codesign --force --sign "$IDENTITY" "$APP_BUNDLE" >/dev/null
codesign --verify --strict "$APP_BUNDLE"

# The guard that matters. `spctl` reporting "rejected" is fine — that is the ordinary unidentified
# developer verdict for a locally signed app. A revoked certificate is not fine: macOS would classify
# the app as malware and delete it.
ASSESSMENT="$(spctl --assess --type execute -vv "$APP_BUNDLE" 2>&1 || true)"
if printf '%s' "$ASSESSMENT" | grep -q "CSSMERR_TP_CERT_REVOKED"; then
  echo >&2
  echo "ABORTING: '$IDENTITY' is REVOKED. Signing with it would make macOS treat this app as" >&2
  echo "malware and move it to the Bin. Create a local identity instead:" >&2
  echo "  ./script/create_local_identity.sh" >&2
  rm -rf "$APP_BUNDLE"
  exit 1
fi

# --- launch agent -----------------------------------------------------------------------------

mkdir -p "$(dirname "$AGENT_PLIST")"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null || launchctl load -w "$AGENT_PLIST"

echo
echo "Installed and started."
echo
echo "Grant Full Disk Access once, to this bundle:"
echo "  System Settings -> Privacy & Security -> Full Disk Access -> +"
echo "  $APP_BUNDLE"
echo "then restart it:  launchctl kickstart -k gui/$UID/$BUNDLE_ID"
echo
echo "Because the signature uses a stable certificate, that grant persists across future rebuilds."
echo
echo "Manage:"
echo "  launchctl kickstart -k gui/$UID/$BUNDLE_ID   # restart"
echo "  launchctl bootout gui/$UID/$BUNDLE_ID        # stop until next login"
echo "  rm $AGENT_PLIST                              # uninstall the agent"
