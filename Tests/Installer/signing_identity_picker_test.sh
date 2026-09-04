#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/signing_identity.sh"

HASH_A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
HASH_B="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
HASH_C="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

assert_pick() {
  local expected="$1"
  local valid_listing="$2"
  local all_listing="$3"
  local actual
  actual="$(m3mcp_pick_identity_from_listings "$valid_listing" "$all_listing" || true)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected identity fingerprint %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_pick "" "" "  1) $HASH_A \"M3MCP Local Development Evil\" (CSSMERR_TP_NOT_TRUSTED)"
assert_pick "$HASH_B" "" \
  $'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "M3MCP Local Development Evil" (CSSMERR_TP_NOT_TRUSTED)\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "M3MCP Local Development" (CSSMERR_TP_NOT_TRUSTED)'
assert_pick "" "" "  1) $HASH_A \"M3MCP Local Development\" (CSSMERR_TP_CERT_NOT_VALID_YET)"
assert_pick "" "" "  1) $HASH_A \"M3MCP Local Development\" (CSSMERR_TP_CERT_REVOKED)"
assert_pick "" "" "  1) $HASH_A \"Developer ID Application: Example GmbH (TEAM123456)\" (CSSMERR_TP_NOT_TRUSTED)"
assert_pick "$HASH_A" \
  "  1) $HASH_A \"Developer ID Application: Example GmbH (TEAM123456)\"" ""
assert_pick "" "  1) $HASH_A \"Developer ID Application Evil\"" ""
assert_pick "$HASH_C" \
  "  1) $HASH_C \"Apple Development: Jane Example (TEAM123456)\"" ""
assert_pick "$HASH_A" \
  $'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Duplicate (TEAM123456)"\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Duplicate (TEAM123456)"' ""
assert_pick "$HASH_B" \
  "  1) $HASH_C \"Developer ID Application: Example GmbH (TEAM123456)\"" \
  "  1) $HASH_B \"M3MCP Local Development\" (CSSMERR_TP_NOT_TRUSTED)"

assert_resolve() {
  local expected="$1"
  local explicit="$2"
  local valid_listing="$3"
  local all_listing="$4"
  local actual
  actual="$(m3mcp_resolve_explicit_identity_from_listings "$explicit" "$valid_listing" "$all_listing" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected explicit identity fingerprint %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_resolve "$HASH_A" "$HASH_A" \
  "  1) $HASH_A \"Developer ID Application: Example GmbH (TEAM123456)\"" ""
assert_resolve "$HASH_B" "M3MCP Local Development" "" \
  "  1) $HASH_B \"M3MCP Local Development\" (CSSMERR_TP_NOT_TRUSTED)"
assert_resolve "" "Apple Development: Duplicate (TEAM123456)" \
  $'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Duplicate (TEAM123456)"\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Duplicate (TEAM123456)"' ""
assert_resolve "" "M3MCP Local Development Evil" "" \
  "  1) $HASH_A \"M3MCP Local Development Evil\" (CSSMERR_TP_NOT_TRUSTED)"
assert_resolve "" "$HASH_A" "" \
  "  1) $HASH_A \"M3MCP Local Development\" (CSSMERR_TP_CERT_REVOKED)"

grep -qF 'source "$ROOT_DIR/script/signing_identity.sh"' "$ROOT_DIR/script/build_and_run.sh"
grep -qF 'source "$ROOT_DIR/script/signing_identity.sh"' "$ROOT_DIR/script/install_local.sh"
grep -qF 'find-identity -p codesigning -v' "$ROOT_DIR/script/build_and_run.sh"
grep -qF 'find-identity -p codesigning -v' "$ROOT_DIR/script/install_local.sh"
grep -qF 'm3mcp_pick_identity_from_listings "$valid" "$all"' "$ROOT_DIR/script/build_and_run.sh"
grep -qF 'm3mcp_pick_identity_from_listings "$valid" "$all"' "$ROOT_DIR/script/install_local.sh"
grep -qF 'm3mcp_resolve_explicit_identity_from_listings "$M3MCP_CODESIGN_IDENTITY" "$valid" "$all"' "$ROOT_DIR/script/build_and_run.sh"
grep -qF 'm3mcp_resolve_explicit_identity_from_listings "$M3MCP_CODESIGN_IDENTITY" "$valid" "$all"' "$ROOT_DIR/script/install_local.sh"
grep -qF 'm3mcp_resolve_explicit_identity_from_listings "$M3MCP_CODESIGN_IDENTITY" "$valid" "$all"' "$ROOT_DIR/script/package_release.sh"
if grep -qF 'm3mcp_pick_identity()' "$ROOT_DIR/script/lib/codesign.sh"; then
  echo "script/lib/codesign.sh must not define a second identity picker" >&2
  exit 1
fi

echo "signing identity picker tests: OK"
