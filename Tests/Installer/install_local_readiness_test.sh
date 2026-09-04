#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT_DIR/script/install_local.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/m3mcp-installer-readiness.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
MOCK_IDENTITY_FINGERPRINT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_case() {
  local name="$1"
  CASE_ROOT="$TEST_ROOT/$name"
  CASE_HOME="$CASE_ROOT/home"
  CASE_INSTALL_DIR="$CASE_ROOT/install"
  CASE_BUILD_DIR="$CASE_ROOT/build"
  CASE_MOCK_BIN="$CASE_ROOT/bin"
  CASE_COMMAND_LOG="$CASE_ROOT/commands.log"
  CASE_CURL_COUNT="$CASE_ROOT/curl.count"
  CASE_OUTPUT="$CASE_ROOT/installer.log"

  mkdir -p \
    "$CASE_HOME/Library/LaunchAgents" \
    "$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS" \
    "$CASE_BUILD_DIR" \
    "$CASE_MOCK_BIN"

  printf 'old-app\n' > "$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS/M3MCPApp"
  chmod +x "$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS/M3MCPApp"
  printf 'old-agent\n' > "$CASE_HOME/Library/LaunchAgents/de.markzimmermann.m3mcp.plist"
  printf '#!/bin/sh\nexit 0\n# new-app\n' > "$CASE_BUILD_DIR/M3MCPApp"
  chmod +x "$CASE_BUILD_DIR/M3MCPApp"

  cat > "$CASE_MOCK_BIN/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

command_name="${0##*/}"
printf '%s %s\n' "$command_name" "$*" >> "$MOCK_COMMAND_LOG"

case "$command_name" in
  swift)
    if [[ " $* " == *" --show-bin-path "* ]]; then
      printf '%s\n' "$MOCK_BUILD_DIR"
    fi
    ;;
  curl)
    count=0
    if [[ -f "$MOCK_CURL_COUNT_FILE" ]]; then
      IFS= read -r count < "$MOCK_CURL_COUNT_FILE" || true
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_CURL_COUNT_FILE"
    case "$MOCK_HEALTH_MODE" in
      unhealthy)
        # HTTP transport succeeds, but the app reports that it is not operational.
        printf '{"ok":false,"endpoint":"mock"}'
        ;;
      healthy_after_two)
        if ((count < 3)); then
          printf '{"ok":false,"endpoint":"mock"}'
        else
          printf '{"ok":true,"endpoint":"mock"}'
        fi
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  codesign)
    if [[ -n "${MOCK_FAIL_VERIFY_PATH:-}" \
          && " $* " == *" --verify "* \
          && " $* " == *" $MOCK_FAIL_VERIFY_PATH "* ]]; then
      exit 65
    fi
    ;;
  security)
    printf '  1) %s "Apple Development: M3MCP Test (TESTTEAM01)"\n' \
      "$MOCK_IDENTITY_FINGERPRINT"
    ;;
  launchctl|pkill|sleep|spctl|xattr)
    ;;
  *)
    echo "unexpected mocked command: $command_name" >&2
    exit 64
    ;;
esac
MOCK
  chmod +x "$CASE_MOCK_BIN/mock-command"

  local command_name
  for command_name in codesign curl launchctl pkill security sleep spctl swift xattr; do
    ln -s mock-command "$CASE_MOCK_BIN/$command_name"
  done
}

run_installer() {
  local health_mode="$1"
  local fail_verify_path="${2:-}"
  set +e
  /usr/bin/env -i \
    HOME="$CASE_HOME" \
    PATH="$CASE_MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    M3MCP_CODESIGN_IDENTITY="$MOCK_IDENTITY_FINGERPRINT" \
    M3MCP_INSTALL_DIR="$CASE_INSTALL_DIR" \
    MOCK_BUILD_DIR="$CASE_BUILD_DIR" \
    MOCK_COMMAND_LOG="$CASE_COMMAND_LOG" \
    MOCK_CURL_COUNT_FILE="$CASE_CURL_COUNT" \
    MOCK_HEALTH_MODE="$health_mode" \
    MOCK_FAIL_VERIFY_PATH="$fail_verify_path" \
    MOCK_IDENTITY_FINGERPRINT="$MOCK_IDENTITY_FINGERPRINT" \
    /bin/bash "$INSTALLER" > "$CASE_OUTPUT" 2>&1
  CASE_STATUS=$?
  set -e
}

test_live_path_verification_failure_stops_replacement_before_rollback() {
  setup_case live_path_failure
  run_installer healthy_after_two "$CASE_INSTALL_DIR/M3MCP.app"

  [[ "$CASE_STATUS" -ne 0 ]] || fail "live replacement verification failure committed"
  [[ "$(<"$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS/M3MCPApp")" == "old-app" ]] \
    || fail "previous app was not restored after live-path failure"
  [[ "$(<"$CASE_HOME/Library/LaunchAgents/de.markzimmermann.m3mcp.plist")" == "old-agent" ]] \
    || fail "previous agent changed during live-path failure"
  [[ "$(grep -c '^launchctl bootout ' "$CASE_COMMAND_LOG")" == "1" ]] \
    || fail "rollback did not stop a replacement that KeepAlive could have launched"
  [[ "$(grep -c '^pkill -x M3MCPApp' "$CASE_COMMAND_LOG")" == "1" ]] \
    || fail "rollback did not terminate a replacement process by executable name"
  [[ "$(grep -c '^launchctl bootstrap ' "$CASE_COMMAND_LOG")" == "1" ]] \
    || fail "rollback did not restart exactly the previous loaded service"
  [[ ! -e "$CASE_CURL_COUNT" ]] \
    || fail "readiness probing started after the live bundle verification had failed"
  assert_no_transaction_leftovers
}

assert_no_transaction_leftovers() {
  local install_leftovers
  local agent_leftovers
  install_leftovers="$(find "$CASE_INSTALL_DIR" -maxdepth 1 -name '.M3MCP.*' -print)"
  agent_leftovers="$(find "$CASE_HOME/Library/LaunchAgents" -maxdepth 1 -name '.de.markzimmermann.m3mcp.*' -print)"
  [[ -z "$install_leftovers" ]] || fail "application transaction leftovers remain: $install_leftovers"
  [[ -z "$agent_leftovers" ]] || fail "LaunchAgent transaction leftovers remain: $agent_leftovers"
}

test_unhealthy_response_rolls_back() {
  setup_case unhealthy
  run_installer unhealthy

  [[ "$CASE_STATUS" -ne 0 ]] || fail "an unhealthy /health response committed the installation"
  [[ "$(<"$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS/M3MCPApp")" == "old-app" ]] \
    || fail "previous application was not restored"
  [[ "$(<"$CASE_HOME/Library/LaunchAgents/de.markzimmermann.m3mcp.plist")" == "old-agent" ]] \
    || fail "previous LaunchAgent was not restored"
  [[ "$(<"$CASE_CURL_COUNT")" == "40" ]] \
    || fail "readiness retry count was not bounded at 40 attempts"
  [[ "$(grep -c '^launchctl bootstrap ' "$CASE_COMMAND_LOG")" == "2" ]] \
    || fail "rollback did not restart the previously loaded service"
  grep -Fq "did not return a healthy /health response" "$CASE_OUTPUT" \
    || fail "installer did not explain the readiness failure"
  grep -Fq -- "--unix-socket $CASE_HOME/Library/Application Support/M3MCP/mcp.sock" "$CASE_COMMAND_LOG" \
    || fail "readiness probe did not use the isolated default Unix socket"
  if grep -Fq "Installed and started." "$CASE_OUTPUT"; then
    fail "installer announced success before readiness"
  fi
  assert_no_transaction_leftovers
}

test_health_success_commits_after_retry() {
  setup_case healthy
  run_installer healthy_after_two

  [[ "$CASE_STATUS" -eq 0 ]] || fail "healthy replacement did not commit"
  grep -Fq '# new-app' "$CASE_INSTALL_DIR/M3MCP.app/Contents/MacOS/M3MCPApp" \
    || fail "replacement application was not retained"
  grep -Fq '<key>Label</key>' "$CASE_HOME/Library/LaunchAgents/de.markzimmermann.m3mcp.plist" \
    || fail "replacement LaunchAgent was not retained"
  [[ "$(<"$CASE_CURL_COUNT")" == "3" ]] \
    || fail "installer did not wait for the first healthy response"
  [[ "$(grep -c '^launchctl bootstrap ' "$CASE_COMMAND_LOG")" == "1" ]] \
    || fail "successful installation unexpectedly restarted the old service"
  grep -Fq "Installed and started." "$CASE_OUTPUT" \
    || fail "installer did not announce success after readiness"
  assert_no_transaction_leftovers
}

test_unhealthy_response_rolls_back
test_health_success_commits_after_retry
test_live_path_verification_failure_stops_replacement_before_rollback
echo "install_local readiness tests passed"
