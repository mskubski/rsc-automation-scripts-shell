#!/bin/bash
# ==============================================================================
# rsc_auth.sh
#
# Shared authentication helper for RSC scripts.
# Source this file, then call: get_rsc_token
#
# The function sets RSC_TOKEN in the calling script's environment.
# Tokens are cached in .rsc_token_cache (same directory as this file)
# and reused until they are within TOKEN_BUFFER_SECONDS of expiry.
# This avoids exhausting Rubrik's 10-token-per-service-account limit.
#
# Cache file permissions are set to 600 (owner read/write only).
# ==============================================================================

# Seconds before actual expiry at which the token is considered stale.
# Default: 300 s (5 minutes). Increase if your scripts run back-to-back.
TOKEN_BUFFER_SECONDS=${TOKEN_BUFFER_SECONDS:-300}

_RSC_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TOKEN_CACHE="$_RSC_AUTH_DIR/.rsc_token_cache"

# ------------------------------------------------------------------------------
# _decode_jwt_exp <token>
# Decodes the JWT payload and returns the exp (Unix timestamp), or 0 on failure.
# ------------------------------------------------------------------------------
_decode_jwt_exp() {
  local token="$1"
  local payload

  payload=$(echo "$token" | cut -d'.' -f2)

  # JWT uses base64url encoding — restore standard base64 and pad to multiple of 4
  payload=$(echo "$payload" | tr '_-' '/+')
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac

  echo "$payload" | base64 -d 2>/dev/null | jq -r '.exp // 0'
}

# ------------------------------------------------------------------------------
# get_rsc_token
# Sets RSC_TOKEN. Reads from cache if still valid, otherwise fetches a new one.
# Requires RSC_TOKEN_URI, RSC_CLIENT_ID, RSC_CLIENT_SECRET to be set.
# ------------------------------------------------------------------------------
get_rsc_token() {
  local cached_token exp now

  # --- Try the cache first ---
  if [[ -f "$_TOKEN_CACHE" ]]; then
    cached_token=$(cat "$_TOKEN_CACHE")

    if [[ -n "$cached_token" ]]; then
      exp=$(_decode_jwt_exp "$cached_token")
      now=$(date +%s)

      if (( exp > now + TOKEN_BUFFER_SECONDS )); then
        RSC_TOKEN="$cached_token"
        echo "-> Using cached token (expires in $(( exp - now ))s)."
        return 0
      else
        echo "-> Cached token expired or within buffer window. Requesting new token..."
      fi
    fi
  fi

  # --- Request a new token ---
  local response token
  response=$(curl --silent --location "$RSC_TOKEN_URI" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data "client_id=$RSC_CLIENT_ID&client_secret=$RSC_CLIENT_SECRET&grant_type=client_credentials")

  token=$(echo "$response" | jq -r '.access_token // empty')

  if [[ -z "$token" ]]; then
    echo "Error: Failed to obtain access token from RSC." >&2
    echo "Response: $response" >&2
    return 1
  fi

  # Cache with restricted permissions
  echo "$token" > "$_TOKEN_CACHE"
  chmod 600 "$_TOKEN_CACHE"

  exp=$(_decode_jwt_exp "$token")
  now=$(date +%s)
  echo "-> New token obtained (expires in $(( exp - now ))s, cached to .rsc_token_cache)."

  RSC_TOKEN="$token"
}
