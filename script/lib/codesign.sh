#!/usr/bin/env bash
# Shared post-sign assessment. Identity discovery and exact fingerprint resolution live in
# script/signing_identity.sh; this file deliberately contains no second picker.
m3mcp_reject_expired_or_revoked_signature() {
  local bundle="$1" identity="$2" assessment
  assessment="$(spctl --assess --type execute -vv "$bundle" 2>&1 || true)"
  if printf '%s' "$assessment" | /usr/bin/grep -qE "CSSMERR_TP_CERT_(EXPIRED|REVOKED)"; then
    echo >&2
    echo "ABORTING: '$identity' is expired or revoked. macOS may reject this app or treat it as" >&2
    echo "malicious. Create a fresh local identity instead:" >&2
    echo "  ./script/create_local_identity.sh" >&2
    return 1
  fi
  return 0
}
