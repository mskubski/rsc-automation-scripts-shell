#!/bin/bash
# ==============================================================================
# getAllclusters.sh
#
# Description:
#   Queries all Rubrik clusters registered in RSC and displays them as a
#   readable summary — one block per cluster with nodes, capacity, and status.
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash getAllclusters.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
# 1. AUTHENTICATE
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. QUERY ALL CLUSTERS
# ==============================================================================
echo ""
echo "Fetching cluster inventory..."

RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n '{query: "query {
    clusterConnection(filter: {}) {
      nodes {
        name id type version defaultAddress
        systemStatus status subStatus pauseStatus
        encryptionEnabled eosDate estimatedRunway
        geoLocation { address }
        metric {
          totalCapacity usedCapacity availableCapacity
          averageDailyGrowth lastUpdateTime
        }
        clusterNodeConnection {
          nodes { hostname ipAddress status }
        }
      }
    }
  }"}')" \
  "https://$RSC_FQDN/api/graphql")

if echo "$RESPONSE" | jq -e '.errors' &>/dev/null; then
  echo "Error: API returned errors:" >&2
  echo "$RESPONSE" | jq '.errors' >&2
  exit 1
fi

CLUSTER_COUNT=$(echo "$RESPONSE" | jq '.data.clusterConnection.nodes | length')
if [[ "$CLUSTER_COUNT" == "0" || "$CLUSTER_COUNT" == "null" ]]; then
  echo "No clusters found." >&2; exit 1
fi

# ==============================================================================
# 3. DISPLAY — one block per cluster
# ==============================================================================
echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  RSC Cluster Inventory  ($CLUSTER_COUNT cluster(s))"
echo "════════════════════════════════════════════════════════════════════════"

echo "$RESPONSE" | jq -c '.data.clusterConnection.nodes[]' | while IFS= read -r CLUSTER; do

  NAME=$(echo    "$CLUSTER" | jq -r '.name')
  TYPE=$(echo    "$CLUSTER" | jq -r '.type // "-"')
  VERSION=$(echo "$CLUSTER" | jq -r '.version // "-"')
  ADDRESS=$(echo "$CLUSTER" | jq -r '.defaultAddress // "-"')
  STATUS=$(echo  "$CLUSTER" | jq -r '.status // "-"')
  SUBSTATUS=$(echo "$CLUSTER" | jq -r '.subStatus // "-"')
  SYS_STATUS=$(echo "$CLUSTER" | jq -r '.systemStatus // "-"')
  PAUSE=$(echo   "$CLUSTER" | jq -r '.pauseStatus // "-"')
  ENCRYPT=$(echo "$CLUSTER" | jq -r 'if .encryptionEnabled then "Yes" else "No" end')
  EOS=$(echo     "$CLUSTER" | jq -r '.eosDate // "-"' | cut -c1-10)
  RUNWAY=$(echo  "$CLUSTER" | jq -r '.estimatedRunway // "-"')
  GEO=$(echo     "$CLUSTER" | jq -r '.geoLocation.address // "-"')

  TOTAL_TB=$(echo  "$CLUSTER" | jq -r '(.metric.totalCapacity     // 0) / 1099511627776 | . * 100 | round / 100')
  USED_TB=$(echo   "$CLUSTER" | jq -r '(.metric.usedCapacity      // 0) / 1099511627776 | . * 100 | round / 100')
  FREE_TB=$(echo   "$CLUSTER" | jq -r '(.metric.availableCapacity // 0) / 1099511627776 | . * 100 | round / 100')
  GROWTH=$(echo    "$CLUSTER" | jq -r '(.metric.averageDailyGrowth // 0) / 1073741824 | . * 100 | round / 100')
  LAST_UPD=$(echo  "$CLUSTER" | jq -r '.metric.lastUpdateTime // "-"' | cut -c1-19 | tr 'T' ' ')

  # Capacity percentage
  USE_PCT=$(echo "$CLUSTER" | jq -r '
    if (.metric.totalCapacity // 0) > 0
    then ((.metric.usedCapacity // 0) / .metric.totalCapacity * 100) | round
    else 0 end')

  NODE_COUNT=$(echo "$CLUSTER" | jq '.clusterNodeConnection.nodes | length')

  echo ""
  echo "  ┌─ $NAME"
  printf "  │  %-18s %s\n"  "Type:"        "$TYPE"
  printf "  │  %-18s %s\n"  "Version:"     "$VERSION"
  printf "  │  %-18s %s\n"  "Address:"     "$ADDRESS"
  printf "  │  %-18s %s\n"  "Location:"    "$GEO"
  printf "  │  %-18s %s  (system: %s  pause: %s)\n" "Status:" "$STATUS / $SUBSTATUS" "$SYS_STATUS" "$PAUSE"
  printf "  │  %-18s %s\n"  "Encryption:"  "$ENCRYPT"
  printf "  │  %-18s %s\n"  "EOS Date:"    "$EOS"
  printf "  │\n"
  printf "  │  %-18s %s TB used / %s TB total (%s%%)  —  %s TB free\n" \
    "Storage:" "$USED_TB" "$TOTAL_TB" "$USE_PCT" "$FREE_TB"
  printf "  │  %-18s %s GB/day\n"  "Daily Growth:" "$GROWTH"
  printf "  │  %-18s %s days\n"    "Est. Runway:"  "$RUNWAY"
  printf "  │  %-18s %s\n"         "Last Updated:" "$LAST_UPD"
  printf "  │\n"
  printf "  │  Nodes (%s):\n" "$NODE_COUNT"
  printf "  │    %-32s %-16s %s\n" "Hostname" "IP Address" "Status"
  printf "  │    %s\n" "──────────────────────────────────────────────────────"

  echo "$CLUSTER" | jq -r '.clusterNodeConnection.nodes[] |
    "\(.hostname // "-")\t\(.ipAddress // "-")\t\(.status // "-")"
  ' | while IFS=$'\t' read -r HN IP ST; do
    printf "  │    %-32s %-16s %s\n" "$HN" "$IP" "$ST"
  done

  echo "  └────────────────────────────────────────────────────────────────"
done

echo ""
