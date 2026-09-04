#!/usr/bin/env bash

# Pure parsing helpers shared by the development runner and installer. Inputs are the literal
# outputs of `security find-identity -p codesigning -v` and its unfiltered counterpart; no command
# is executed here. The result is the inspected certificate fingerprint, never an ambiguous CN.
m3mcp_identity_matches_class() {
  local candidate="$1"
  local identity_class="$2"

  case "$identity_class" in
    local)
      [[ "$candidate" == "M3MCP Local Development" ]]
      ;;
    developer_id)
      [[ "$candidate" == "Developer ID Application: "* \
        && "$candidate" != "Developer ID Application: " ]]
      ;;
    apple_development)
      [[ "$candidate" == "Apple Development: "* \
        && "$candidate" != "Apple Development: " ]]
      ;;
    *)
      return 1
      ;;
  esac
}

m3mcp_identity_matches_supported_class() {
  local candidate="$1"
  m3mcp_identity_matches_class "$candidate" local \
    || m3mcp_identity_matches_class "$candidate" developer_id \
    || m3mcp_identity_matches_class "$candidate" apple_development
}

m3mcp_pick_from_listing() {
  local listing="$1"
  local identity_class="$2"
  local accepted_state="$3"
  local line prefix ordinal fingerprint ignored remainder candidate

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$accepted_state" in
      valid)
        [[ "$line" != *CSSMERR* ]] || continue
        ;;
      local_self_signed)
        [[ "$line" == *" (CSSMERR_TP_NOT_TRUSTED)" ]] || continue
        ;;
      *)
        return 1
        ;;
    esac

    prefix="${line%%\"*}"
    IFS=' ' read -r ordinal fingerprint ignored <<< "$prefix"
    [[ "$ordinal" =~ ^[0-9]+\)$ && "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || continue

    remainder="${line#*\"}"
    [[ "$remainder" != "$line" && "$remainder" == *\"* ]] || continue
    candidate="${remainder%%\"*}"
    if m3mcp_identity_matches_class "$candidate" "$identity_class"; then
      printf '%s' "$fingerprint"
      return 0
    fi
  done < <(printf '%s\n' "$listing")
  return 1
}

m3mcp_pick_identity_from_listings() {
  local valid_listing="$1"
  local all_listing="$2"
  local fingerprint

  fingerprint="$(m3mcp_pick_from_listing "$valid_listing" local valid || true)"
  if [[ -z "$fingerprint" ]]; then
    fingerprint="$(m3mcp_pick_from_listing "$all_listing" local local_self_signed || true)"
  fi
  if [[ -n "$fingerprint" ]]; then
    printf '%s' "$fingerprint"
    return 0
  fi

  fingerprint="$(m3mcp_pick_from_listing "$valid_listing" developer_id valid || true)"
  if [[ -z "$fingerprint" ]]; then
    fingerprint="$(m3mcp_pick_from_listing "$valid_listing" apple_development valid || true)"
  fi
  [[ -n "$fingerprint" ]] || return 1
  printf '%s' "$fingerprint"
}

# Resolves a caller-supplied fingerprint or exact certificate name to one inspected fingerprint.
# Apple-issued identities are accepted only from the verified listing. The unfiltered listing is
# consulted only for the exact local self-signed identity in its expected NOT_TRUSTED state.
# Ambiguous names and unsupported certificate classes fail closed.
m3mcp_matches_for_explicit_identity() {
  local listing="$1"
  local accepted_state="$2"
  local explicit="$3"
  local explicit_fingerprint line prefix ordinal fingerprint ignored remainder candidate normalized

  explicit_fingerprint="$(printf '%s' "$explicit" | /usr/bin/tr '[:lower:]' '[:upper:]')"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$accepted_state" in
      valid)
        [[ "$line" != *CSSMERR* ]] || continue
        ;;
      local_self_signed)
        [[ "$line" == *" (CSSMERR_TP_NOT_TRUSTED)" ]] || continue
        ;;
      *)
        return 1
        ;;
    esac

    prefix="${line%%\"*}"
    IFS=' ' read -r ordinal fingerprint ignored <<< "$prefix"
    [[ "$ordinal" =~ ^[0-9]+\)$ && "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || continue

    remainder="${line#*\"}"
    [[ "$remainder" != "$line" && "$remainder" == *\"* ]] || continue
    candidate="${remainder%%\"*}"
    m3mcp_identity_matches_supported_class "$candidate" || continue
    if [[ "$accepted_state" == "local_self_signed" && "$candidate" != "M3MCP Local Development" ]]; then
      continue
    fi

    normalized="$(printf '%s' "$fingerprint" | /usr/bin/tr '[:lower:]' '[:upper:]')"
    if [[ "$explicit_fingerprint" =~ ^[[:xdigit:]]{40}$ ]]; then
      [[ "$normalized" == "$explicit_fingerprint" ]] || continue
    else
      [[ "$candidate" == "$explicit" ]] || continue
    fi
    printf '%s\n' "$normalized"
  done < <(printf '%s\n' "$listing")
}

m3mcp_resolve_explicit_identity_from_listings() {
  local explicit="$1"
  local valid_listing="$2"
  local all_listing="$3"
  local matches count

  [[ -n "$explicit" ]] || return 1
  matches="$({
    m3mcp_matches_for_explicit_identity "$valid_listing" valid "$explicit"
    m3mcp_matches_for_explicit_identity "$all_listing" local_self_signed "$explicit"
  } | LC_ALL=C /usr/bin/sort -u)"
  count="$(printf '%s\n' "$matches" | /usr/bin/grep -c . || true)"
  if [[ "$count" != "1" ]]; then
    echo "Explicit signing identity '$explicit' resolved to $count supported fingerprints; expected exactly one." >&2
    return 1
  fi
  printf '%s' "$matches"
}
