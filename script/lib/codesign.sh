#!/usr/bin/env bash
# The signing identity rules, in one place.
#
# script/install_local.sh had these rules inline. script/package_release.sh needs exactly the same
# ones, so they moved here instead of being written a second time: an identity picked one way for
# the local install and another way for the release artifact is a difference nobody would notice
# until a user reports a signature the other path never produces.
#
# This file is sourced, not executed. It sets no options of its own so it cannot change the
# behaviour of the script that sources it.

# Prints the name of a usable code-signing identity, or nothing.
#
# Preference order: the local self-signed identity first, then Developer ID, then Apple Development.
# The local one is preferred because it cannot expire mid-project and gives a certificate-based
# designated requirement, so privacy grants survive rebuilds.
#
# Only expiry and revocation disqualify a certificate. CSSMERR_TP_NOT_TRUSTED is the normal state
# for a self-signed certificate and codesign accepts it, so it must not be filtered out.
m3mcp_pick_identity() {
  if [[ -n "${M3MCP_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$M3MCP_CODESIGN_IDENTITY"
    return
  fi
  local all name line reason
  all="$(security find-identity -p codesigning 2>/dev/null || true)"
  for name in "M3MCP Local Development" "Developer ID Application" "Apple Development"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if printf '%s' "$line" | grep -qE "CSSMERR_TP_CERT_(EXPIRED|REVOKED)"; then
        reason="$(printf '%s' "$line" | sed 's/.*(\(CSSMERR[^)]*\)).*/\1/')"
        echo "Skipping unusable identity ($reason): $name" >&2
        continue
      fi
      printf '%s\n' "$line" | sed 's/.*"\(.*\)".*/\1/'
      return
    done < <(printf '%s\n' "$all" | grep -F "\"$name")
  done
}

# Refuses to continue if the bundle was signed with a revoked certificate.
#
# spctl reporting "rejected" is fine, that is the ordinary unidentified-developer verdict for a
# locally signed app. A revoked certificate is not fine: macOS classifies the app as malware and
# moves it to the Bin.
m3mcp_reject_revoked_signature() {
  local bundle="$1" identity="$2" assessment
  assessment="$(spctl --assess --type execute -vv "$bundle" 2>&1 || true)"
  if printf '%s' "$assessment" | grep -q "CSSMERR_TP_CERT_REVOKED"; then
    echo >&2
    echo "ABORTING: '$identity' is REVOKED. Signing with it would make macOS treat this app as" >&2
    echo "malware and move it to the Bin. Create a local identity instead:" >&2
    echo "  ./script/create_local_identity.sh" >&2
    return 1
  fi
  return 0
}
