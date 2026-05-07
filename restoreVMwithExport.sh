#!/bin/bash
# ==============================================================================
# restoreVMwithExport.sh
#
# Description:
#   Interactively exports a VMware vSphere VM snapshot to a new VM (non-destructive).
#   Unlike in-place recovery, this creates a new VM from the selected snapshot
#   without modifying or removing the original VM.
#
#   Prompts for all parameters the RSC GUI asks for:
#     - Compute target (ESXi host)
#     - Datastore (default: first available on selected host)
#     - Network (default: keep original)
#     - New VM name (default: original name)
#     - Power on after export (default: yes)
#
# Flow:
#   1. List all VMs — user selects one by number
#   2. List all snapshots for the selected VM (newest first) — user selects one
#   3. Select compute target (ESXi host)
#   4. Select datastore
#   5. Select network (optional — keep original by default)
#   6. Enter new VM name and power-on preference
#   7. Confirm before proceeding
#   8. Initiate export via vsphereVmExportSnapshotV2
#   9. Poll job status and stream progress until export completes
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash restoreVMwithExport.sh
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
# HELPERS
# ==============================================================================
gql() {
  local response
  response=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")
  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "API error:" >&2; echo "$response" | jq '.errors' >&2; exit 1
  fi
  echo "$response"
}

gql_vars() {
  local response
  response=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')" \
    "https://$RSC_FQDN/api/graphql")
  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "API error:" >&2; echo "$response" | jq '.errors' >&2; exit 1
  fi
  echo "$response"
}

# Soft query — returns raw response without exiting on API error (used for fallbacks)
gql_soft() {
  curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql"
}

# ==============================================================================
# 1. AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. LIST ALL VMs
# ==============================================================================
echo ""
echo "Fetching VM inventory..."

VM_RESPONSE=$(gql "query {
  vSphereVmNewConnection(filter: [
    {field: IS_RELIC texts: \"false\"},
    {field: IS_REPLICATED texts: \"false\"}
  ]) {
    nodes {
      id
      name
      cluster { id name }
      effectiveSlaDomain { name }
      powerStatus
    }
  }
}")

VM_COUNT=$(echo "$VM_RESPONSE" | jq '.data.vSphereVmNewConnection.nodes | length')

if [[ "$VM_COUNT" -eq 0 ]]; then
  echo "Error: No VMs found in inventory." >&2; exit 1
fi

echo ""
echo "Available VMs:"
echo "────────────────────────────────────────────────────────────────────"
printf "  %-4s %-38s %-18s %s\n" "No." "VM Name" "SLA" "Power"
echo "────────────────────────────────────────────────────────────────────"

for i in $(seq 0 $((VM_COUNT - 1))); do
  VM_NAME=$(echo "$VM_RESPONSE"  | jq -r ".data.vSphereVmNewConnection.nodes[$i].name")
  SLA_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$i].effectiveSlaDomain.name")
  POWER=$(echo "$VM_RESPONSE"    | jq -r ".data.vSphereVmNewConnection.nodes[$i].powerStatus // \"-\"")
  printf "  %-4s %-38s %-18s %s\n" "$((i + 1))" "$VM_NAME" "$SLA_NAME" "$POWER"
done

echo "────────────────────────────────────────────────────────────────────"
echo ""
read -rp "Select VM to export from (number): " VM_SEL

if ! [[ "$VM_SEL" =~ ^[0-9]+$ ]] || (( VM_SEL < 1 || VM_SEL > VM_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

IDX=$((VM_SEL - 1))
VM_ID=$(echo "$VM_RESPONSE"        | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].id")
VM_NAME=$(echo "$VM_RESPONSE"      | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].name")
CLUSTER_ID=$(echo "$VM_RESPONSE"   | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.id")
CLUSTER_NAME=$(echo "$VM_RESPONSE" | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.name")

# ==============================================================================
# 3. LIST SNAPSHOTS FOR SELECTED VM (newest first, max 30)
# ==============================================================================
echo ""
echo "Fetching snapshots for: $VM_NAME ..."

SNAP_RESPONSE=$(gql "query {
  vSphereVmNew(fid: \"$VM_ID\") {
    snapshotConnection {
      nodes {
        id
        date
        isOnDemandSnapshot
      }
    }
  }
}")

SNAP_COUNT=$(echo "$SNAP_RESPONSE" | jq '.data.vSphereVmNew.snapshotConnection.nodes | length')

if [[ "$SNAP_COUNT" -eq 0 ]]; then
  echo "Error: No snapshots found for $VM_NAME." >&2; exit 1
fi

DISPLAY_COUNT=$SNAP_COUNT
if (( DISPLAY_COUNT > 30 )); then DISPLAY_COUNT=30; fi

SORTED_SNAPS=$(echo "$SNAP_RESPONSE" | jq '
  [.data.vSphereVmNew.snapshotConnection.nodes[]
  | {id, date, isOnDemandSnapshot}]
  | sort_by(.date) | reverse')

echo ""
echo "Snapshots for $VM_NAME (showing $DISPLAY_COUNT of $SNAP_COUNT, newest first):"
echo "────────────────────────────────────────────────────────────────────"
printf "  %-4s %-30s %s\n" "No." "Date / Time (UTC)" "Type"
echo "────────────────────────────────────────────────────────────────────"

for i in $(seq 0 $((DISPLAY_COUNT - 1))); do
  SNAP_DATE=$(echo "$SORTED_SNAPS" | jq -r ".[$i].date")
  IS_OD=$(echo "$SORTED_SNAPS"     | jq -r ".[$i].isOnDemandSnapshot")
  SNAP_TYPE="Scheduled"
  [[ "$IS_OD" == "true" ]] && SNAP_TYPE="On-demand"
  printf "  %-4s %-30s %s\n" "$((i + 1))" "$SNAP_DATE" "$SNAP_TYPE"
done

echo "────────────────────────────────────────────────────────────────────"
echo ""
read -rp "Select snapshot to export from (number): " SNAP_SEL

if ! [[ "$SNAP_SEL" =~ ^[0-9]+$ ]] || (( SNAP_SEL < 1 || SNAP_SEL > DISPLAY_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

SNAP_IDX=$((SNAP_SEL - 1))
SNAP_ID=$(echo "$SORTED_SNAPS"   | jq -r ".[$SNAP_IDX].id")
SNAP_DATE=$(echo "$SORTED_SNAPS" | jq -r ".[$SNAP_IDX].date")

# ==============================================================================
# 4. SELECT DATASTORE  (also collects networks for step 5)
# ==============================================================================
echo ""
echo "Fetching datastores and networks..."

HOST_FID=""
HOST_NAME=""
DS_NODES="[]"
NET_NODES="[]"

# Get VM's ESXi host FID from physicalPath
PHYS_RESP=$(gql_soft "query {
  vSphereVmNew(fid: \"$VM_ID\") {
    physicalPath { fid name objectType }
  }
}")
HOST_FID=$(echo "$PHYS_RESP" | jq -r '
  (.data.vSphereVmNew.physicalPath // [])[]
  | select(.objectType == "VSphereHost")
  | .fid' 2>/dev/null | head -1)
HOST_NAME=$(echo "$PHYS_RESP" | jq -r '
  (.data.vSphereVmNew.physicalPath // [])[]
  | select(.objectType == "VSphereHost")
  | .name' 2>/dev/null | head -1)

# descendantConnection returns all child objects including datastores and networks
if [[ -n "$HOST_FID" ]]; then
  DESC_RESP=$(gql_soft "query {
    vSphereHost(fid: \"$HOST_FID\") {
      descendantConnection { nodes { id name objectType } }
    }
  }")
  DS_NODES=$(echo "$DESC_RESP" | jq \
    '[(.data.vSphereHost.descendantConnection.nodes // [])[] | select(.objectType == "VSphereDatastore")]')
  NET_NODES=$(echo "$DESC_RESP" | jq \
    '[(.data.vSphereHost.descendantConnection.nodes // [])[] | select(.objectType == "VSphereNetwork")]')
fi

DS_COUNT=$(echo "$DS_NODES" | jq 'length')
EXPORT_DS_ID=""
EXPORT_DS_NAME=""

if [[ "$DS_COUNT" -gt 0 ]]; then
  echo ""
  echo "Select datastore (host: ${HOST_NAME:-unknown}):"
  echo "────────────────────────────────────────────────────────────────────"
  printf "  %-4s %s\n" "No." "Datastore Name"
  echo "────────────────────────────────────────────────────────────────────"

  for i in $(seq 0 $((DS_COUNT - 1))); do
    DS_NAME=$(echo "$DS_NODES" | jq -r ".[$i].name")
    printf "  %-4s %s\n" "$((i + 1))" "$DS_NAME"
  done

  echo "────────────────────────────────────────────────────────────────────"
  echo ""
  read -rp "Select datastore (number) [default: 1]: " DS_SEL
  if [[ -z "$DS_SEL" ]]; then DS_SEL=1; fi

  if ! [[ "$DS_SEL" =~ ^[0-9]+$ ]] || (( DS_SEL < 1 || DS_SEL > DS_COUNT )); then
    echo "Error: Invalid selection." >&2; exit 1
  fi

  DS_IDX=$((DS_SEL - 1))
  EXPORT_DS_ID=$(echo "$DS_NODES" | jq -r ".[$DS_IDX].id")
  EXPORT_DS_NAME=$(echo "$DS_NODES" | jq -r ".[$DS_IDX].name")

else
  echo ""
  echo "  No datastores found via API. Enter the RSC datastore ID manually."
  echo "  (RSC UI: Infrastructure → vSphere → select datastore → copy ID from URL)"
  echo ""
  while [[ -z "$EXPORT_DS_ID" ]]; do
    read -rp "  Datastore ID (required): " EXPORT_DS_ID
    [[ -z "$EXPORT_DS_ID" ]] && echo "  datastoreId is required." >&2
  done
  EXPORT_DS_NAME="$EXPORT_DS_ID"
fi

# ==============================================================================
# 5. SHOW NETWORKS (informational — original assignments kept by the export API)
# ==============================================================================
EXPORT_NET_NAME="(keep original)"
NET_COUNT=$(echo "$NET_NODES" | jq 'length')

if [[ "$NET_COUNT" -gt 0 ]]; then
  echo ""
  echo "Networks available on host ${HOST_NAME:-}:"
  echo "────────────────────────────────────────────────────────────────────"
  for i in $(seq 0 $((NET_COUNT - 1))); do
    printf "  - %s\n" "$(echo "$NET_NODES" | jq -r ".[$i].name")"
  done
  echo "────────────────────────────────────────────────────────────────────"
  echo "  The exported VM will keep its original network assignments."
  echo "  Reassign networks in vSphere after export if needed."
else
  echo ""
  echo "  (No networks found — original network assignments will be kept)"
fi

# ==============================================================================
# 6. VM NAME AND POWER-ON PREFERENCE
# ==============================================================================
echo ""
read -rp "New VM name [default: $VM_NAME]: " NEW_VM_NAME
if [[ -z "$NEW_VM_NAME" ]]; then NEW_VM_NAME="$VM_NAME"; fi

echo ""
read -rp "Power on VM after export? [Y/n]: " POWER_ON_INPUT
POWER_ON=true
case "$POWER_ON_INPUT" in
  n|N|no|NO|No) POWER_ON=false ;;
esac

# ==============================================================================
# 7. CONFIRM
# ==============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  EXPORT CONFIRMATION"
echo "══════════════════════════════════════════════════════════════════"
echo "  Source VM   : $VM_NAME"
echo "  Snapshot    : $SNAP_DATE"
echo "  ──────────────────────────────────────────────────────────────"
echo "  New VM name : $NEW_VM_NAME"
echo "  Datastore   : $EXPORT_DS_NAME"
echo "  Network     : $EXPORT_NET_NAME"
echo "  Power on    : $POWER_ON"
echo "══════════════════════════════════════════════════════════════════"
echo ""
read -rp "Type YES to confirm and start the export: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Export cancelled."
  exit 0
fi

# ==============================================================================
# 8. INITIATE EXPORT
# ==============================================================================
echo ""
echo "Initiating export..."

RESTORE_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RESTORE_START_EPOCH=$(date +%s)

MUTATION='mutation ExportSnapshot($input: VsphereVmExportSnapshotV2Input!) {
  vsphereVmExportSnapshotV2(input: $input) {
    id
    status
    startTime
    error { message }
  }
}'

# ExportSnapshotJobConfigV2Input confirmed fields (via schema introspection):
#   datastoreId (String!, required)
#   hostId (String, optional)
#   mountExportSnapshotJobCommonOptionsV2 (MountExportSnapshotJobCommonOptionsV2Input):
#     vmName, powerOn, keepMacAddresses, disableNetwork
CONFIG=$(jq -n \
  --arg  ds "$EXPORT_DS_ID" \
  --arg  vm "$NEW_VM_NAME" \
  --argjson po "$POWER_ON" \
  '{
    datastoreId: $ds,
    mountExportSnapshotJobCommonOptionsV2: {
      vmName: $vm,
      powerOn: $po,
      keepMacAddresses: false,
      disableNetwork: false
    }
  }')

# hostId is optional but tells RSC which host to use
if [[ -n "$HOST_FID" ]]; then
  CONFIG=$(echo "$CONFIG" | jq --arg h "$HOST_FID" '. + {hostId: $h}')
fi

VARIABLES=$(jq -n \
  --arg     snapId "$SNAP_ID" \
  --argjson config "$CONFIG" \
  '{input: {id: $snapId, config: $config}}')

EXPORT_RESPONSE=$(gql_vars "$MUTATION" "$VARIABLES")

JOB_ID=$(echo "$EXPORT_RESPONSE" | jq -r '.data.vsphereVmExportSnapshotV2.id // empty')

if [[ -z "$JOB_ID" ]]; then
  echo "Error: Failed to initiate export — no job ID returned." >&2
  echo "$EXPORT_RESPONSE" | jq '.' >&2
  exit 1
fi

echo "-> Export job started. Job ID: $JOB_ID"
echo ""

# ==============================================================================
# 9. MONITOR — activitySeriesConnection (primary) + vSphereVMAsyncRequestStatus (secondary)
#
# vSphereVMAsyncRequestStatus supplements progress % and timestamps.
# activitySeriesConnection is the authoritative source for terminal state.
# ==============================================================================
echo "Monitoring export progress (polling every 15s)..."
echo "────────────────────────────────────────────────────────────────────"

LAST_LINE=""
POLL_INTERVAL=15

while true; do

  TIMESTAMP=$(date '+%H:%M:%S')

  # Primary: activitySeriesConnection
  ACTIVITY_RESP=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "query {
      activitySeriesConnection(filters: {
        objectFid: \"$VM_ID\"
        lastActivityType: [Recovery]
        lastUpdatedTimeGt: \"$RESTORE_START_TIME\"
      }) {
        nodes {
          lastActivityMessage
          progress
          failureReason
          causeErrorMessage
          activityConnection(first: 1) {
            nodes { status message }
          }
        }
      }
    }" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  NODES=$(echo "$ACTIVITY_RESP" | jq '(.data.activitySeriesConnection.nodes // []) | first // {}')

  ACT_STATUS=$(echo "$NODES"   | jq -r '(.activityConnection.nodes // []) | first | .status // "Queued"')
  ACT_MSG=$(echo "$NODES"      | jq -r '.lastActivityMessage // ""')
  ACT_PROGRESS=$(echo "$NODES" | jq -r '.progress // 0')
  ACT_ERROR=$(echo "$NODES"    | jq -r '.failureReason // .causeErrorMessage // ""')

  PROGRESS_INT=$(echo "$ACT_PROGRESS" | awk '{printf "%d", $1}')

  # Secondary: vSphereVMAsyncRequestStatus (best-effort)
  ASYNC_RESP=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "query { vSphereVMAsyncRequestStatus(id: \"$JOB_ID\" clusterUuid: \"$CLUSTER_ID\") { status progress endTime startTime error { message } } }" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  ASYNC_STATUS=$(echo "$ASYNC_RESP" | jq -r '.data.vSphereVMAsyncRequestStatus.status   // ""')
  ASYNC_END=$(echo "$ASYNC_RESP"    | jq -r '.data.vSphereVMAsyncRequestStatus.endTime   // "-"')
  ASYNC_START=$(echo "$ASYNC_RESP"  | jq -r '.data.vSphereVMAsyncRequestStatus.startTime // "-"')

  if [[ "$PROGRESS_INT" -eq 0 && -n "$ASYNC_STATUS" ]]; then
    ASYNC_PROG=$(echo "$ASYNC_RESP" | jq -r '.data.vSphereVMAsyncRequestStatus.progress // 0')
    PROGRESS_INT=$(echo "$ASYNC_PROG" | awk '{printf "%d", $1}')
  fi

  # Determine effective status (activity is authoritative)
  case "$ACT_STATUS" in
    Success|TaskSuccess) EFF_STATUS="SUCCEEDED" ;;
    Failure|TaskFailure) EFF_STATUS="FAILED" ;;
    Canceled|Canceling)  EFF_STATUS="CANCELED" ;;
    Running)             EFF_STATUS="RUNNING" ;;
    Queued)              EFF_STATUS="QUEUED" ;;
    *)
      case "$ASYNC_STATUS" in
        SUCCEEDED) EFF_STATUS="SUCCEEDED" ;;
        FAILED)    EFF_STATUS="FAILED" ;;
        CANCELED)  EFF_STATUS="CANCELED" ;;
        RUNNING)   EFF_STATUS="RUNNING" ;;
        QUEUED)    EFF_STATUS="QUEUED" ;;
        *)         EFF_STATUS="RUNNING" ;;
      esac
      ;;
  esac

  case "$EFF_STATUS" in
    QUEUED)    STATUS_LABEL="Queued" ;;
    RUNNING)   STATUS_LABEL="Exporting... ${PROGRESS_INT}%" ;;
    SUCCEEDED) STATUS_LABEL="Export complete" ;;
    FAILED)    STATUS_LABEL="Failed" ;;
    CANCELED)  STATUS_LABEL="Canceled" ;;
    *)         STATUS_LABEL="$EFF_STATUS" ;;
  esac

  CURRENT_LINE="[$TIMESTAMP]  $STATUS_LABEL"
  [[ -n "$ACT_MSG" ]] && CURRENT_LINE="$CURRENT_LINE  |  $ACT_MSG"

  if [[ "$CURRENT_LINE" != "$LAST_LINE" ]]; then
    echo "$CURRENT_LINE"
    LAST_LINE="$CURRENT_LINE"
  fi

  case "$EFF_STATUS" in
    SUCCEEDED)
      RESTORE_END_EPOCH=$(date +%s)
      DURATION=$(( RESTORE_END_EPOCH - RESTORE_START_EPOCH ))
      DURATION_FMT=$(printf '%dm %ds' $(( DURATION / 60 )) $(( DURATION % 60 )))
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Export completed successfully."
      echo "  Source VM   : $VM_NAME"
      echo "  Snapshot    : $SNAP_DATE"
      echo "  Cluster     : $CLUSTER_NAME"
      echo "  New VM name : $NEW_VM_NAME"
      echo "  Datastore   : $EXPORT_DS_NAME"
      echo "  Network     : $EXPORT_NET_NAME"
      echo "  Power on    : $POWER_ON"
      echo "  Duration    : $DURATION_FMT"
      echo "  Start time  : ${ASYNC_START:--}"
      echo "  End time    : ${ASYNC_END:--}"
      echo "  Job ID      : $JOB_ID"
      exit 0
      ;;
    FAILED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Export failed." >&2
      echo "  Source VM : $VM_NAME" >&2
      echo "  Error     : ${ACT_ERROR:-$ACT_MSG}" >&2
      echo "  Job ID    : $JOB_ID" >&2
      exit 1
      ;;
    CANCELED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Export was canceled." >&2
      echo "  Source VM : $VM_NAME" >&2
      echo "  Job ID    : $JOB_ID" >&2
      exit 1
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
