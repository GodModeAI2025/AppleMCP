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
#  - Refuses expired or revoked certificates before replacing a working installation. Signing with
#    a revoked certificate can make macOS treat the app as malware and move it to the Bin.
#
#  - Runs the app from launchd rather than a shell. This matters for Full Disk Access: TCC evaluates
#    the *responsible* process, so an app started from a terminal inherits the terminal's grant
#    instead of using its own. Under launchd the app is its own responsible process, so the grant you
#    give this bundle is the grant that applies.
set -euo pipefail

APP_NAME="M3MCPApp"
BRIDGE_NAME="M3MCPBridge"
BUNDLE_NAME="M3MCP"
BUNDLE_ID="de.markzimmermann.m3mcp"
CONFIGURATION="${M3MCP_CONFIGURATION:-release}"
INSTALL_DIR="${M3MCP_INSTALL_DIR:-$HOME/Applications}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/codesign.sh
source "$ROOT_DIR/script/lib/codesign.sh"

APP_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BRIDGE_BINARY="$APP_BUNDLE/Contents/MacOS/$BRIDGE_NAME"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
AGENT_DIR="${AGENT_PLIST%/*}"
SOURCE_INFO_PLIST="$ROOT_DIR/Sources/$APP_NAME/Resources/Info.plist"
source "$ROOT_DIR/script/signing_identity.sh"

# Keep all replacement work off the live paths. The state flags let the EXIT trap distinguish
# between a temporary-file cleanup and a rename that must be rolled back.
STAGING_ROOT=""
STAGED_APP=""
STAGED_APP_BINARY=""
BACKUP_ROOT=""
BACKUP_APP=""
STAGED_AGENT_PLIST=""
AGENT_BACKUP_ROOT=""
BACKUP_AGENT_PLIST=""
HAD_EXISTING_APP=0
OLD_APP_BACKED_UP=0
NEW_APP_INSTALLED=0
OLD_AGENT_BACKED_UP=0
NEW_AGENT_INSTALLED=0
SERVICE_WAS_LOADED=0
SERVICE_STOPPED=0
INSTALL_COMPLETE=0
HEALTH_SOCKET="$HOME/Library/Application Support/M3MCP/mcp.sock"
READINESS_ATTEMPTS=40
READINESS_DELAY_SECONDS="0.25"
READINESS_CURL_TIMEOUT_SECONDS="0.5"

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

service_is_ready() {
  local response
  local health_ok

  # A successful bootstrap only means launchd accepted the plist. Require both a loaded job and the
  # app's own health response so a crash-on-launch or failed socket bind remains rollback-eligible.
  launchctl print "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1 || return 1
  response="$(
    curl \
      --disable \
      --fail \
      --silent \
      --show-error \
      --noproxy '*' \
      --connect-timeout "$READINESS_CURL_TIMEOUT_SECONDS" \
      --max-time "$READINESS_CURL_TIMEOUT_SECONDS" \
      --unix-socket "$HEALTH_SOCKET" \
      http://localhost/health \
      2>/dev/null
  )" || return 1
  health_ok="$(
    printf '%s' "$response" \
      | /usr/bin/plutil -extract ok raw -o - - 2>/dev/null \
      || true
  )"
  [[ "$health_ok" == "true" ]]
}

wait_for_service_readiness() {
  local attempt
  for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
    if service_is_ready; then
      return 0
    fi
    if ((attempt < READINESS_ATTEMPTS)); then
      sleep "$READINESS_DELAY_SECONDS"
    fi
  done
  return 1
}

# rm is limited to paths returned by mktemp with the expected parent and prefix. In particular,
# neither INSTALL_DIR nor the live application path is ever passed to rm -rf.
remove_created_tree() {
  local candidate="${1:-}"
  local expected_parent="$2"
  local expected_prefix="$3"
  [[ -z "$candidate" ]] && return 0
  if [[ "${candidate%/*}" != "$expected_parent" || "${candidate##*/}" != "$expected_prefix"* ]]; then
    echo "Refusing to clean unexpected temporary path: $candidate" >&2
    return 1
  fi
  rm -rf -- "$candidate"
}

remove_created_file() {
  local candidate="${1:-}"
  local expected_parent="$2"
  local expected_prefix="$3"
  [[ -z "$candidate" ]] && return 0
  if [[ "${candidate%/*}" != "$expected_parent" || "${candidate##*/}" != "$expected_prefix"* ]]; then
    echo "Refusing to clean unexpected temporary path: $candidate" >&2
    return 1
  fi
  rm -f -- "$candidate"
}

rollback_and_cleanup() {
  local status=$?
  local failed_app="$STAGING_ROOT/failed-$BUNDLE_NAME.app"
  trap - EXIT HUP INT TERM
  set +e

  if [[ "$INSTALL_COMPLETE" -ne 1 ]]; then
    # A bootstrap may have succeeded immediately before a later command or signal failed the
    # transaction. Stop any replacement process before putting the old files back in place.
    if [[ "$SERVICE_STOPPED" -eq 1 \
          || ( "$SERVICE_WAS_LOADED" -eq 1 \
               && ( "$NEW_APP_INSTALLED" -eq 1 || "$NEW_AGENT_INSTALLED" -eq 1 ) ) ]]; then
      # A KeepAlive job can restart in the short window after a live path is replaced but before
      # the normal commit-time bootout. Treat exposure of either replacement as stop-required so
      # rollback cannot leave a process running code from files that are about to be restored.
      SERVICE_STOPPED=1
      launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
      pkill -x "$APP_NAME" 2>/dev/null || true
    fi

    if [[ "$NEW_AGENT_INSTALLED" -eq 1 ]] && path_exists "$AGENT_PLIST"; then
      if mv -- "$AGENT_PLIST" "$STAGED_AGENT_PLIST"; then
        NEW_AGENT_INSTALLED=0
      else
        echo "WARNING: could not move the failed launch-agent replacement out of the way." >&2
      fi
    fi
    if [[ "$OLD_AGENT_BACKED_UP" -eq 1 ]] && ! path_exists "$AGENT_PLIST"; then
      if mv -- "$BACKUP_AGENT_PLIST" "$AGENT_PLIST"; then
        OLD_AGENT_BACKED_UP=0
      else
        echo "WARNING: could not restore the previous launch-agent plist." >&2
      fi
    fi

    if [[ "$NEW_APP_INSTALLED" -eq 1 ]] && path_exists "$APP_BUNDLE"; then
      if mv -- "$APP_BUNDLE" "$failed_app"; then
        NEW_APP_INSTALLED=0
      else
        echo "WARNING: could not move the failed application replacement out of the way." >&2
      fi
    fi
    if [[ "$OLD_APP_BACKED_UP" -eq 1 ]] && ! path_exists "$APP_BUNDLE"; then
      if mv -- "$BACKUP_APP" "$APP_BUNDLE"; then
        OLD_APP_BACKED_UP=0
      else
        echo "WARNING: could not restore the previous application bundle." >&2
      fi
    fi

    if [[ "$HAD_EXISTING_APP" -eq 1 && "$OLD_APP_BACKED_UP" -eq 0 ]]; then
      echo "Installation failed; the previous application bundle was restored." >&2
    fi

    # If this installer stopped a previously loaded service, make a best-effort attempt to resume
    # it after its old bundle and plist have both been restored.
    if [[ "$SERVICE_WAS_LOADED" -eq 1 && "$SERVICE_STOPPED" -eq 1 \
          && "$OLD_APP_BACKED_UP" -eq 0 && "$OLD_AGENT_BACKED_UP" -eq 0 \
          && -f "$AGENT_PLIST" ]]; then
      launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null \
        || launchctl load -w "$AGENT_PLIST" 2>/dev/null \
        || echo "WARNING: the previous app was restored but could not be restarted automatically." >&2
    fi
  fi

  remove_created_file "$STAGED_AGENT_PLIST" "$AGENT_DIR" ".$BUNDLE_ID.install." || true
  remove_created_tree "$STAGING_ROOT" "$INSTALL_DIR" ".$BUNDLE_NAME.install." || true

  if [[ "$INSTALL_COMPLETE" -eq 1 || "$OLD_APP_BACKED_UP" -eq 0 ]]; then
    remove_created_tree "$BACKUP_ROOT" "$INSTALL_DIR" ".$BUNDLE_NAME.backup." || true
  elif [[ -n "$BACKUP_ROOT" ]]; then
    echo "Previous application retained for manual recovery at: $BACKUP_ROOT" >&2
  fi

  if [[ "$INSTALL_COMPLETE" -eq 1 || "$OLD_AGENT_BACKED_UP" -eq 0 ]]; then
    remove_created_tree "$AGENT_BACKUP_ROOT" "$AGENT_DIR" ".$BUNDLE_ID.backup." || true
  elif [[ -n "$AGENT_BACKUP_ROOT" ]]; then
    echo "Previous launch-agent plist retained for manual recovery at: $AGENT_BACKUP_ROOT" >&2
  fi

  exit "$status"
}

trap rollback_and_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

xml_escape() {
  /usr/bin/sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\\&apos;/g"
}

APP_BINARY_XML="$(printf '%s' "$APP_BINARY" | xml_escape)"

# Persist only explicit, fixed-name security opt-ins in the launch agent. launchd does not inherit
# arbitrary variables from the shell that ran this installer, so without this block an installation
# would silently fall back to the safe profile even when the user deliberately opted in.
is_explicit_true() {
  local normalized
  normalized="$(printf '%s' "${1:-}" \
    | /usr/bin/tr '[:upper:]' '[:lower:]' \
    | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$normalized" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

POLICY_ENV_ENTRIES=""
for policy_key in \
  M3MCP_ENABLE_CALENDAR_MUTATIONS \
  M3MCP_ENABLE_PERMISSION_UI \
  M3MCP_ENABLE_USER_SHORTCUTS
do
  case "$policy_key" in
    M3MCP_ENABLE_CALENDAR_MUTATIONS)
      policy_value="${M3MCP_ENABLE_CALENDAR_MUTATIONS:-}"
      ;;
    M3MCP_ENABLE_PERMISSION_UI)
      policy_value="${M3MCP_ENABLE_PERMISSION_UI:-}"
      ;;
    M3MCP_ENABLE_USER_SHORTCUTS)
      policy_value="${M3MCP_ENABLE_USER_SHORTCUTS:-}"
      ;;
  esac
  if is_explicit_true "$policy_value"; then
    POLICY_ENV_ENTRIES="$POLICY_ENV_ENTRIES
    <key>$policy_key</key>
    <string>1</string>"
  fi
done

POLICY_ENV_BLOCK=""
if [[ -n "$POLICY_ENV_ENTRIES" ]]; then
  POLICY_ENV_BLOCK="  <key>EnvironmentVariables</key>
  <dict>$POLICY_ENV_ENTRIES
  </dict>"
fi

# --- signing identity -------------------------------------------------------------------------

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
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BUILT_BINARY="$BIN_PATH/$APP_NAME"
BUILT_BRIDGE="$BIN_PATH/$BRIDGE_NAME"
[[ -x "$BUILT_BINARY" ]] || { echo "Build produced no binary at $BUILT_BINARY" >&2; exit 1; }
[[ -x "$BUILT_BRIDGE" ]] || { echo "Build produced no bridge at $BUILT_BRIDGE" >&2; exit 1; }

# --- assemble and validate replacements --------------------------------------------------------

echo "Installing to $APP_BUNDLE"
mkdir -p "$INSTALL_DIR"
STAGING_ROOT="$(mktemp -d "$INSTALL_DIR/.$BUNDLE_NAME.install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$BUNDLE_NAME.app"
STAGED_APP_BINARY="$STAGED_APP/Contents/MacOS/$APP_NAME"
STAGED_BRIDGE_BINARY="$STAGED_APP/Contents/MacOS/$BRIDGE_NAME"

mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$BUILT_BINARY" "$STAGED_APP_BINARY"
chmod +x "$STAGED_APP_BINARY"
# The bridge goes in beside the app, the same way script/package_release.sh puts it there. The app
# pins the client it accepts to the M3MCPBridge next to its own executable, so an installation
# without this file falls back to token-only and says so in its window and in /health.
cp "$BUILT_BRIDGE" "$STAGED_BRIDGE_BINARY"
chmod +x "$STAGED_BRIDGE_BINARY"
cp "$SOURCE_INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
xattr -cr "$STAGED_APP" 2>/dev/null || true
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

# --- sign -------------------------------------------------------------------------------------

# Nested code first, then the main executable, then the bundle: a later signature seals what came
# before it.
codesign --force --sign "$IDENTITY" "$STAGED_BRIDGE_BINARY" >/dev/null
codesign --force --sign "$IDENTITY" "$STAGED_APP_BINARY" >/dev/null
codesign --force --sign "$IDENTITY" "$STAGED_APP" >/dev/null
codesign --verify --strict "$STAGED_APP"

# A normal local or self-signed bundle may be rejected by Gatekeeper. Expired or revoked
# certificate states are different and make the staged replacement ineligible for installation.
m3mcp_reject_expired_or_revoked_signature "$STAGED_APP" "$IDENTITY"

# Render and lint the launch agent off its live path as well. This keeps a failed plist update from
# damaging an otherwise working installation.
mkdir -p "$AGENT_DIR"
STAGED_AGENT_PLIST="$(mktemp "$AGENT_DIR/.$BUNDLE_ID.install.XXXXXX")"
cat > "$STAGED_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BINARY_XML</string>
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
$POLICY_ENV_BLOCK
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$STAGED_AGENT_PLIST" >/dev/null

# --- commit with rollback ---------------------------------------------------------------------

# Record this before changing either path. A failure after stopping the service can then restore
# and restart exactly the previously loaded installation.
if launchctl print "gui/$UID/$BUNDLE_ID" >/dev/null 2>&1; then
  SERVICE_WAS_LOADED=1
fi

if path_exists "$APP_BUNDLE"; then
  HAD_EXISTING_APP=1
  BACKUP_ROOT="$(mktemp -d "$INSTALL_DIR/.$BUNDLE_NAME.backup.XXXXXX")"
  BACKUP_APP="$BACKUP_ROOT/$BUNDLE_NAME.app"
  OLD_APP_BACKED_UP=1
  if ! mv -- "$APP_BUNDLE" "$BACKUP_APP"; then
    OLD_APP_BACKED_UP=0
    exit 1
  fi
fi

NEW_APP_INSTALLED=1
if ! mv -- "$STAGED_APP" "$APP_BUNDLE"; then
  NEW_APP_INSTALLED=0
  exit 1
fi
[[ -x "$APP_BINARY" ]] || { echo "Installed bundle has no executable at $APP_BINARY" >&2; exit 1; }
[[ -x "$BRIDGE_BINARY" ]] || { echo "Installed bundle has no bridge at $BRIDGE_BINARY" >&2; exit 1; }
codesign --verify --strict "$APP_BUNDLE"

if path_exists "$AGENT_PLIST"; then
  AGENT_BACKUP_ROOT="$(mktemp -d "$AGENT_DIR/.$BUNDLE_ID.backup.XXXXXX")"
  BACKUP_AGENT_PLIST="$AGENT_BACKUP_ROOT/${AGENT_PLIST##*/}"
  OLD_AGENT_BACKED_UP=1
  if ! mv -- "$AGENT_PLIST" "$BACKUP_AGENT_PLIST"; then
    OLD_AGENT_BACKED_UP=0
    exit 1
  fi
fi

NEW_AGENT_INSTALLED=1
if ! mv -- "$STAGED_AGENT_PLIST" "$AGENT_PLIST"; then
  NEW_AGENT_INSTALLED=0
  exit 1
fi

# Only now, after both replacements are ready and rollback copies exist, interrupt the old process.
SERVICE_STOPPED=1
launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null || launchctl load -w "$AGENT_PLIST"
if ! wait_for_service_readiness; then
  echo "Installation failed: the replacement launchd job did not return a healthy /health response on $HEALTH_SOCKET." >&2
  exit 1
fi
INSTALL_COMPLETE=1

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
echo "Point your MCP client at the bridge that was installed with the app:"
echo "  $BRIDGE_BINARY"
echo "and give it the capability token from the app's Server menu (Copy MCP Client Token):"
echo '  "env": { "M3MCP_TOKEN": "<token>" }'
echo "Without the token the app refuses every tool call. A bridge from anywhere else is refused too:"
echo "the app accepts only the code directory hash of the bridge sitting next to it."
echo
echo "Manage:"
echo "  launchctl kickstart -k gui/$UID/$BUNDLE_ID   # restart"
echo "  launchctl bootout gui/$UID/$BUNDLE_ID        # stop until next login"
echo "  rm $AGENT_PLIST                              # uninstall the agent"
