#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/m3mcp-identity-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN" "$TEST_ROOT/home/Library/Keychains"

cat > "$MOCK_BIN/security" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "find-identity -p codesigning -v" ]]; then
  case "${IDENTITY_TEST_MODE:-}" in
    valid)
      printf '  1) ABCDEF "M3MCP Local Development"\n'
      ;;
    near_match)
      if [[ -f "${IDENTITY_TEST_STATE:?}" ]]; then
        printf '  1) ABCDEF "M3MCP Local Development"\n'
      else
        printf '  1) ABCDEF "M3MCP Local Development Evil"\n'
      fi
      ;;
  esac
  exit 0
fi

if [[ "$*" == "find-identity -p codesigning" ]]; then
  case "${IDENTITY_TEST_MODE:-}" in
    expired)
      printf '  1) ABCDEF "M3MCP Local Development" (CSSMERR_TP_CERT_EXPIRED)\n'
      ;;
    revoked)
      printf '  1) ABCDEF "M3MCP Local Development" (CSSMERR_TP_CERT_REVOKED)\n'
      ;;
    untrusted)
      printf '  1) ABCDEF "M3MCP Local Development" (CSSMERR_TP_NOT_TRUSTED)\n'
      ;;
    unknown)
      printf '  1) ABCDEF "M3MCP Local Development" (CSSMERR_SOMETHING_ELSE)\n'
      ;;
    near_match)
      if [[ -f "${IDENTITY_TEST_STATE:?}" ]]; then
        printf '  1) ABCDEF "M3MCP Local Development" (CSSMERR_TP_NOT_TRUSTED)\n'
      else
        printf '  1) ABCDEF "M3MCP Local Development Evil" (CSSMERR_TP_NOT_TRUSTED)\n'
      fi
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "import" && "${IDENTITY_TEST_MODE:-}" == "near_match" ]]; then
  : >"${IDENTITY_TEST_STATE:?}"
  exit 0
fi

printf 'unexpected security invocation: %s\n' "$*" >&2
exit 99
MOCK
chmod +x "$MOCK_BIN/security"

cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

previous=""
for argument in "$@"; do
  if [[ "$previous" == "-out" || "$previous" == "-keyout" ]]; then
    : >"$argument"
  fi
  previous="$argument"
done
MOCK
chmod +x "$MOCK_BIN/openssl"

run_case() {
  local mode="$1"
  local expected_status="$2"
  local expected_text="$3"
  local output="$TEST_ROOT/$mode.out"
  local status=0

  IDENTITY_TEST_MODE="$mode" \
    IDENTITY_TEST_STATE="$TEST_ROOT/$mode.state" \
    HOME="$TEST_ROOT/home" \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    bash "$ROOT_DIR/script/create_local_identity.sh" >"$output" 2>&1 || status=$?

  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'case %s: expected status %s, got %s\n' "$mode" "$expected_status" "$status" >&2
    cat "$output" >&2
    exit 1
  fi
  if ! grep -qF "$expected_text" "$output"; then
    printf 'case %s: missing expected output %s\n' "$mode" "$expected_text" >&2
    cat "$output" >&2
    exit 1
  fi
}

run_case valid 0 "already exists and is valid"
run_case untrusted 0 "self-signed"
run_case expired 1 "security delete-identity"
run_case revoked 1 "security delete-identity"
run_case unknown 1 "not a usable code-signing identity"
run_case near_match 0 "Created 'M3MCP Local Development'"

echo "create_local_identity status tests: OK"
