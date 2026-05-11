#!/bin/bash
# ==============================================================================
# VMsize.sh
#
# Description:
#   Lists all vSphere VMs with their VM storage size and total backup storage
#   used on Rubrik, sorted by VM size descending.
#
#   VM Used (GB)     = usedCapacityBytes reported by vSphere (datastore usage)
#   Backup Used (GB) = sum of physicalBytes across all local snapshots on Rubrik
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash VMsize.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load credentials
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "Error: .env file not found at $SCRIPT_DIR/.env" >&2; exit 1
fi
source "$SCRIPT_DIR/.env"

: "${RSC_FQDN:?Error: RSC_FQDN not set in .env}"
: "${RSC_CLIENT_ID:?Error: RSC_CLIENT_ID not set in .env}"
: "${RSC_CLIENT_SECRET:?Error: RSC_CLIENT_SECRET not set in .env}"
: "${RSC_TOKEN_URI:?Error: RSC_TOKEN_URI not set in .env}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2; exit 1
fi

# ==============================================================================
# 1. AUTHENTICATE
# ==============================================================================
echo "Authenticating with RSC..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. FETCH VM INVENTORY WITH STORAGE METRICS
# ==============================================================================
echo ""
echo "Fetching VM storage metrics..."

QUERY='query {
  vSphereVmNewConnection(
    filter: [
      {field: IS_RELIC texts: "false"}
      {field: IS_REPLICATED texts: "false"}
    ]
  ) {
    nodes {
      name
      usedCapacityBytes
      snapshotConnection(first: 1000) {
        nodes {
          physicalBytes
        }
      }
    }
  }
}'

RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "$QUERY" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

if echo "$RESPONSE" | jq -e '.errors' &>/dev/null; then
  echo "API error:" >&2
  echo "$RESPONSE" | jq '.errors' >&2
  exit 1
fi

VM_COUNT=$(echo "$RESPONSE" | jq '.data.vSphereVmNewConnection.nodes | length')

if [[ "$VM_COUNT" == "0" || "$VM_COUNT" == "null" ]]; then
  echo "Error: No VMs found." >&2
  exit 1
fi

# ==============================================================================
# 3. BUILD AND DISPLAY SORTED TABLE
# ==============================================================================
# For each VM: emit "<vm_bytes>\t<backup_bytes>\t<name>"
# sort -rn sorts descending by first numeric field (VM size)
# awk converts bytes to GB and formats the table

echo ""
echo "$RESPONSE" | jq -r '
  .data.vSphereVmNewConnection.nodes[] |
  {
    name:         .name,
    vm_bytes:     (.usedCapacityBytes // 0),
    backup_bytes: ([.snapshotConnection.nodes[].physicalBytes // 0] | add // 0)
  } |
  "\(.vm_bytes)\t\(.backup_bytes)\t\(.name)"
' | sort -t $'\t' -k1 -rn | awk -F'\t' '
BEGIN {
  line = "  " sprintf("%-45s", "") "  " sprintf("%14s", "") "  " sprintf("%18s", "")
  sep  = "  ------------------------------------------------------------------------------"
  printf "\n"
  printf "  %-45s  %14s  %18s\n", "VM Name", "VM Used (GB)", "Backup Used (GB)"
  print sep
}
{
  vm_gb     = $1 / 1073741824
  backup_gb = $2 / 1073741824
  printf "  %-45s  %14.2f  %18.2f\n", $3, vm_gb, backup_gb

  total_vm     += $1
  total_backup += $2
  count++
}
END {
  print sep
  printf "  %-45s  %14.2f  %18.2f\n", "TOTAL (" count " VMs)", total_vm / 1073741824, total_backup / 1073741824
  printf "\n"
}
'
