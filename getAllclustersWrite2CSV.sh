#!/bin/bash
# ==============================================================================
# getAllclustersWrite2CSV.sh
#
# Description:
#   Queries all Rubrik clusters registered in RSC and writes results to
#   clusters.csv in the current working directory. Useful for reporting or
#   importing into spreadsheet tools.
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash getAllclustersWrite2CSV.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "Error: .env file not found at $SCRIPT_DIR/.env" >&2; exit 1
fi
source "$SCRIPT_DIR/.env"

: "${RSC_FQDN:?Error: RSC_FQDN not set in .env}"
: "${RSC_CLIENT_ID:?Error: RSC_CLIENT_ID not set in .env}"
: "${RSC_CLIENT_SECRET:?Error: RSC_CLIENT_SECRET not set in .env}"
: "${RSC_TOKEN_URI:?Error: RSC_TOKEN_URI not set in .env}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: brew install jq" >&2; exit 1
fi

# ==============================================================================
# AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# QUERY ALL CLUSTERS
# ==============================================================================
QUERY='query {
  clusterConnection(filter: {}) {
    nodes {
      name id type version defaultAddress
      systemStatus status subStatus pauseStatus
      encryptionEnabled eosDate eosStatus
      registrationTime registeredMode estimatedRunway
      geoLocation { address latitude longitude }
    }
  }
}'

RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "$QUERY" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

if echo "$RESPONSE" | jq -e '.errors' &>/dev/null; then
  echo "Error: API returned errors:" >&2
  echo "$RESPONSE" | jq '.errors' >&2
  exit 1
fi

# ==============================================================================
# WRITE CSV
# ==============================================================================
OUTPUT_CSV="./clusters.csv"

echo "name,id,type,version,defaultAddress,systemStatus,status,subStatus,pauseStatus,encryptionEnabled,eosDate,eosStatus,registrationTime,registeredMode,estimatedRunway,geoAddress,geoLatitude,geoLongitude" > "$OUTPUT_CSV"

echo "$RESPONSE" | jq -r '.data.clusterConnection.nodes[] |
  [
    (.name           // ""),
    (.id             // ""),
    (.type           // ""),
    (.version        // ""),
    (.defaultAddress // ""),
    (.systemStatus   // ""),
    (.status         // ""),
    (.subStatus      // ""),
    (.pauseStatus    // ""),
    (if .encryptionEnabled == true then "true" else "false" end),
    (.eosDate        // ""),
    (.eosStatus      // ""),
    (.registrationTime  // ""),
    (.registeredMode    // ""),
    (.estimatedRunway   // ""),
    (.geoLocation.address   // ""),
    ((.geoLocation.latitude  // "") | tostring),
    ((.geoLocation.longitude // "") | tostring)
  ] | @csv' >> "$OUTPUT_CSV"

echo "Wrote $(( $(wc -l < "$OUTPUT_CSV") - 1 )) cluster(s) to: $OUTPUT_CSV"
