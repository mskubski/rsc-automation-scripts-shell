#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"

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
# 1. AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Authenticating with RSC..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. LIST ALL VMs
# ==============================================================================
echo ""
echo "Fetching VM inventory..."

VM_QUERY='query {
  vSphereVmNewConnection(
    filter: [
      {field: IS_RELIC texts: "false"},
      {field: IS_REPLICATED texts: "false"}
    ]
  ) {
    nodes {
      id
      name
      effectiveSlaDomain {
        id
        name
      }
    }
  }
}'

VM_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "$VM_QUERY" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

VM_COUNT=$(echo "$VM_RESPONSE" | jq '.data.vSphereVmNewConnection.nodes | length')

if [[ "$VM_COUNT" == "0" || "$VM_COUNT" == "null" ]]; then
  echo "Error: No VMs found in inventory." >&2
  exit 1
fi

# ==============================================================================
# 3. DISPLAY VM LIST
# ==============================================================================
echo ""
echo "Available VMs:"
echo "--------------------------------------------------------------"
printf "  %-4s %-40s %s\n" "No." "VM Name" "Assigned SLA"
echo "--------------------------------------------------------------"

for i in $(seq 0 $((VM_COUNT - 1))); do
  VM_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$i].name")
  SLA_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$i].effectiveSlaDomain.name")
  printf "  %-4s %-40s %s\n" "$((i + 1))" "$VM_NAME" "$SLA_NAME"
done

echo "--------------------------------------------------------------"

# ==============================================================================
# 4. USER SELECTION
# ==============================================================================
echo ""
read -rp "Enter the number of the VM to back up: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || (( SELECTION < 1 || SELECTION > VM_COUNT )); then
  echo "Error: Invalid selection. Please enter a number between 1 and $VM_COUNT." >&2
  exit 1
fi

IDX=$((SELECTION - 1))
VM_ID=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].id")
VM_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].name")
SLA_ID=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].effectiveSlaDomain.id")
SLA_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].effectiveSlaDomain.name")

echo ""
echo "Selected VM : $VM_NAME"
echo "Using SLA   : $SLA_NAME"

# ==============================================================================
# 5. TRIGGER ON-DEMAND BACKUP
# ==============================================================================
echo ""
echo "Triggering on-demand backup..."

SNAPSHOT_MUTATION="mutation { vsphereBulkOnDemandSnapshot(input: { config: { vms: [\\\"$VM_ID\\\"] slaId: \\\"$SLA_ID\\\" } }) { responses { id } } }"

SNAPSHOT_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "{\"query\": \"$SNAPSHOT_MUTATION\"}" \
  "https://$RSC_FQDN/api/graphql")

JOB_ID=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.data.vsphereBulkOnDemandSnapshot.responses[0].id')

if [[ -z "$JOB_ID" || "$JOB_ID" == "null" ]]; then
  echo "Error: Failed to start backup." >&2
  echo "Response: $SNAPSHOT_RESPONSE" >&2
  exit 1
fi

echo ""
echo "SUCCESS! On-demand backup started."
echo "  VM      : $VM_NAME"
echo "  SLA     : $SLA_NAME"
echo "  Job ID  : $JOB_ID"
