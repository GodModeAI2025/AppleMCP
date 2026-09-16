#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local development.
#
# Why this exists: macOS privacy grants (Full Disk Access in particular) are pinned to a binary's
# designated requirement. Ad-hoc signatures put the cdhash in that requirement, so every rebuild
# invalidates the grant and you re-authorise the app by hand. A stable certificate produces a
# requirement based on the certificate instead, and the grant survives rebuilds.
#
# A self-signed certificate is also safer here than a real Apple one: signing with an expired or
# revoked certificate makes Gatekeeper treat the app as malicious and move it to the Bin, which is a
# far worse failure than the ordinary "unidentified developer" prompt.
set -euo pipefail

IDENTITY_NAME="${M3MCP_IDENTITY:-M3MCP Local Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_lines_named() {
  # `security find-identity` prints the certificate common name as one quoted field. Compare that
  # field exactly: a substring check would confuse e.g. "M3MCP Local Development Evil" with the
  # requested identity and could silently reuse the wrong signing state.
  awk -v expected="$IDENTITY_NAME" '
    match($0, /"[^"]*"/) {
      candidate = substr($0, RSTART + 1, RLENGTH - 2)
      if (candidate == expected) print
    }
  '
}

VALID_IDENTITIES="$(security find-identity -p codesigning -v 2>/dev/null \
  | identity_lines_named || true)"
if [[ -n "$VALID_IDENTITIES" ]]; then
  echo "Identity '$IDENTITY_NAME' already exists and is valid. Nothing to do."
  exit 0
fi

MATCHING_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null \
  | identity_lines_named || true)"
if [[ -n "$MATCHING_IDENTITIES" ]]; then
  if printf '%s\n' "$MATCHING_IDENTITIES" | grep -qE 'CSSMERR_TP_CERT_(EXPIRED|REVOKED)'; then
    echo "Identity '$IDENTITY_NAME' exists but is expired or revoked; it cannot be reused." >&2
    echo "Remove that exact identity, then rerun this script:" >&2
    echo "  security delete-identity -c '$IDENTITY_NAME' '$KEYCHAIN'" >&2
    echo "Or choose a new unique name with M3MCP_IDENTITY." >&2
    exit 1
  fi

  if printf '%s\n' "$MATCHING_IDENTITIES" | grep -q 'CSSMERR_TP_NOT_TRUSTED'; then
    echo "Identity '$IDENTITY_NAME' already exists (self-signed, so macOS reports it as untrusted —"
    echo "that is expected and codesign still accepts it). Nothing to do."
    exit 0
  fi

  echo "Identity '$IDENTITY_NAME' exists but is not a usable code-signing identity." >&2
  echo "Inspect it with 'security find-identity -p codesigning' and either remove the exact" >&2
  echo "identity or choose a new unique name with M3MCP_IDENTITY; no replacement was attempted." >&2
  exit 1
fi

umask 077
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Generating a self-signed code-signing certificate…"
if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
  -subj "/CN=$IDENTITY_NAME/O=M3MCP Local/C=DE" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" > /dev/null 2>"$WORK_DIR/certificate-error"; then
  echo "Code-signing certificate generation failed with $(openssl version)." >&2
  cat "$WORK_DIR/certificate-error" >&2
  exit 1
fi

# Use explicit, macOS-compatible algorithms with both LibreSSL and OpenSSL 3.
# A nonempty transport password is required by some macOS security import versions.
# Keep it out of OpenSSL's command line and never print it.
openssl rand -hex 24 > "$WORK_DIR/password"
P12_PASSWORD="$(cat "$WORK_DIR/password")"
[[ -n "$P12_PASSWORD" ]] || { echo "Could not generate PKCS#12 transport password." >&2; exit 1; }
if ! openssl pkcs12 -export -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -out "$WORK_DIR/identity.p12" -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
  -name "$IDENTITY_NAME" -passout "file:$WORK_DIR/password" 2>"$WORK_DIR/export-error"; then
  echo "PKCS#12 export failed with $(openssl version)." >&2
  cat "$WORK_DIR/export-error" >&2
  exit 1
fi

# This certificate is a privilege, not just a build convenience: anything able to sign with it can
# produce a binary satisfying the app's designated requirement — bundle identifier plus this
# certificate — and thereby inherit the app's Full Disk Access grant. Verified: a stub binary signed
# with this identity and carrying CFBundleIdentifier de.markzimmermann.m3mcp passes
# `codesign --verify -R` against that requirement.
#
# So the default grants the key no standing access at all, and macOS prompts on each build. Neither
# `-A` (any application) nor `-T /usr/bin/codesign` is used by default: `-A` lets malicious code sign
# silently via Security.framework, and `-T /usr/bin/codesign` is barely better, since invoking
# /usr/bin/codesign is something any process can do.
IMPORT_ARGS=()
if [[ -n "${M3MCP_ALLOW_CODESIGN_NOPROMPT:-}" ]]; then
  echo "M3MCP_ALLOW_CODESIGN_NOPROMPT is set — allowing codesign to use the key without prompting."
  echo "This weakens the protection described above. Prefer the default unless builds are frequent."
  IMPORT_ARGS+=(-T /usr/bin/codesign)
fi

# bash 3.2 — the shell macOS actually ships — treats "${arr[@]}" as an unbound variable under
# `set -u` when the array is empty, so the default path (no extra args) aborted here. The
# ${arr[@]+...} guard expands to nothing when unset and is portable back to 3.2.
# security import accepts the transport password through -P. Unlike OpenSSL it
# has no password-file argument. The short-lived random value is not a user secret;
# the private key remains protected by the restrictive keychain ACL below.
if ! security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" ${IMPORT_ARGS[@]+"${IMPORT_ARGS[@]}"} > /dev/null; then
  echo "Keychain import failed; no signing access was broadened." >&2
  exit 1
fi
unset P12_PASSWORD

IMPORTED_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null \
  | identity_lines_named || true)"
if [[ -n "$IMPORTED_IDENTITIES" ]]; then
  echo "Created '$IDENTITY_NAME'."
  echo
  echo "macOS lists it as untrusted (CSSMERR_TP_NOT_TRUSTED) because it is self-signed."
  echo "That is expected — codesign accepts it, and it is what keeps privacy grants stable."
  echo
  echo "SECURITY NOTE: treat this certificate as a privilege, not just a build convenience."
  echo "The app's designated requirement is its bundle identifier plus this certificate, so anything"
  echo "able to sign with it can satisfy that requirement and inherit the app's Full Disk Access."
  echo "That is the trade-off for a grant that survives rebuilds; ad-hoc signing avoids the reusable"
  echo "capability but forces you to re-authorise the app after every build."
  echo
  echo "The key was imported with no standing access, so macOS will ask for authentication the first"
  echo "time each build signs with it. Choose \"Allow\", not \"Always Allow\" — \"Always Allow\" is"
  echo "equivalent to the weaker setup this deliberately avoids."
  echo
  echo "To remove it later:"
  echo "  security delete-identity -c \"$IDENTITY_NAME\""
else
  echo "Import reported success but the identity is not listed. Aborting." >&2
  exit 1
fi
