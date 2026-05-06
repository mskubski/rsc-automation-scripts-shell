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
# 2. LIST ALL VMs  (include cluster id for status polling)
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
      cluster {
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
VM_ID=$(echo "$VM_RESPONSE"       | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].id")
VM_NAME=$(echo "$VM_RESPONSE"     | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].name")
SLA_ID=$(echo "$VM_RESPONSE"      | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].effectiveSlaDomain.id")
SLA_NAME=$(echo "$VM_RESPONSE"    | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].effectiveSlaDomain.name")
CLUSTER_ID=$(echo "$VM_RESPONSE"  | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.id")
CLUSTER_NAME=$(echo "$VM_RESPONSE"| jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.name")

echo ""
echo "Selected VM : $VM_NAME"
echo "Cluster     : $CLUSTER_NAME"
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

echo "-> Backup job started. Job ID: $JOB_ID"

# ==============================================================================
# 6. POLL JOB STATUS
# ==============================================================================
echo ""
echo "Monitoring backup status (polling every 10s)..."
echo "----------------------------------------------------------------"

LAST_STATUS=""
POLL_INTERVAL=10

while true; do
  STATUS_QUERY="query { vSphereVMAsyncRequestStatus( id: \\\"$JOB_ID\\\" clusterUuid: \\\"$CLUSTER_ID\\\" ) { id status progress startTime endTime error { message } } }"

  STATUS_RESPONSE=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "{\"query\": \"$STATUS_QUERY\"}" \
    "https://$RSC_FQDN/api/graphql")

  STATUS=$(echo "$STATUS_RESPONSE"   | jq -r '.data.vSphereVMAsyncRequestStatus.status // "UNKNOWN"')
  PROGRESS=$(echo "$STATUS_RESPONSE" | jq -r '.data.vSphereVMAsyncRequestStatus.progress // 0')
  START_TIME=$(echo "$STATUS_RESPONSE"| jq -r '.data.vSphereVMAsyncRequestStatus.startTime // "-"')
  END_TIME=$(echo "$STATUS_RESPONSE" | jq -r '.data.vSphereVMAsyncRequestStatus.endTime // "-"')
  ERROR_MSG=$(echo "$STATUS_RESPONSE"| jq -r '.data.vSphereVMAsyncRequestStatus.error.message // ""')

  TIMESTAMP=$(date '+%H:%M:%S')

  case "$STATUS" in
    QUEUED)
      MSG="Queued"
      ;;
    RUNNING)
      PROGRESS_INT=$(echo "$PROGRESS" | awk '{printf "%d", $1}')
      MSG="Taking snapshot... ${PROGRESS_INT}%"
      ;;
    SUCCEEDED)
      MSG="Snapshot complete"
      ;;
    FAILED)
      MSG="Failed: $ERROR_MSG"
      ;;
    CANCELED)
      MSG="Canceled"
      ;;
    *)
      MSG="$STATUS"
      ;;
  esac

  # Only print a new line when status or progress changes
  CURRENT_LINE="[$TIMESTAMP]  $VM_NAME  |  $MSG"
  if [[ "$CURRENT_LINE" != "$LAST_STATUS" ]]; then
    echo "$CURRENT_LINE"
    LAST_STATUS="$CURRENT_LINE"
  fi

  case "$STATUS" in
    SUCCEEDED)
      echo "----------------------------------------------------------------"
      echo ""
      echo "Backup completed successfully."
      echo "  VM         : $VM_NAME"
      echo "  SLA        : $SLA_NAME"
      echo "  Cluster    : $CLUSTER_NAME"
      echo "  Start time : $START_TIME"
      echo "  End time   : $END_TIME"
      echo "  Job ID     : $JOB_ID"
      exit 0
      ;;
    FAILED)
      echo "----------------------------------------------------------------"
      echo ""
      echo "Backup failed." >&2
      echo "  VM      : $VM_NAME" >&2
      echo "  Error   : $ERROR_MSG" >&2
      echo "  Job ID  : $JOB_ID" >&2
      exit 1
      ;;
    CANCELED)
      echo "----------------------------------------------------------------"
      echo ""
      echo "Backup was canceled." >&2
      echo "  VM      : $VM_NAME" >&2
      echo "  Job ID  : $JOB_ID" >&2
      exit 1
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
