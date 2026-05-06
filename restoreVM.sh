#!/bin/bash
# ==============================================================================
# restoreVM.sh
#
# Description:
#   Interactively restores a VMware vSphere VM from a selected snapshot using
#   an in-place recovery (overwrites the existing VM with the snapshot state).
#
# Flow:
#   1. List all VMs — user selects one by number
#   2. List all snapshots for the selected VM (newest first) — user selects one
#   3. Confirm before proceeding (restore is destructive)
#   4. Initiate in-place recovery via RSC GraphQL API
#   5. Poll job status and stream activity events until restore completes
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash restoreVM.sh
# ==============================================================================

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
  echo "Error: jq is required but not installed. Run: brew install jq" >&2; exit 1
fi

# ==============================================================================
# HELPER — run a GraphQL query, exit on API errors
# ==============================================================================
rsc_query() {
  local query="$1"
  local response
  response=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$query" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "Error: API returned an error:" >&2
    echo "$response" | jq '.errors' >&2
    exit 1
  fi
  echo "$response"
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

VM_RESPONSE=$(rsc_query "query {
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
read -rp "Select VM to restore (number): " VM_SEL

if ! [[ "$VM_SEL" =~ ^[0-9]+$ ]] || (( VM_SEL < 1 || VM_SEL > VM_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

IDX=$((VM_SEL - 1))
VM_ID=$(echo "$VM_RESPONSE"          | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].id")
VM_NAME=$(echo "$VM_RESPONSE"        | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].name")
CLUSTER_ID=$(echo "$VM_RESPONSE"     | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.id")
CLUSTER_NAME=$(echo "$VM_RESPONSE"   | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.name")

# ==============================================================================
# 3. LIST SNAPSHOTS FOR SELECTED VM (newest first, max 30 shown)
# ==============================================================================
echo ""
echo "Fetching snapshots for: $VM_NAME ..."

SNAP_RESPONSE=$(rsc_query "query {
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

# Sort newest first
SNAP_COUNT=$(echo "$SNAP_RESPONSE" | jq '.data.vSphereVmNew.snapshotConnection.nodes | length')
TOTAL_SNAPS=$SNAP_COUNT

if [[ "$SNAP_COUNT" -eq 0 ]]; then
  echo "Error: No snapshots found for $VM_NAME." >&2; exit 1
fi

# Cap display at 30, sorted newest first
DISPLAY_COUNT=$SNAP_COUNT
if (( DISPLAY_COUNT > 30 )); then DISPLAY_COUNT=30; fi

# Build sorted array (newest first) using jq
SORTED_SNAPS=$(echo "$SNAP_RESPONSE" | jq '
  [.data.vSphereVmNew.snapshotConnection.nodes[]
  | {id, date, isOnDemandSnapshot}]
  | sort_by(.date) | reverse')

echo ""
echo "Snapshots for $VM_NAME (showing $DISPLAY_COUNT of $TOTAL_SNAPS, newest first):"
echo "────────────────────────────────────────────────────────────────────"
printf "  %-4s %-30s %s\n" "No." "Date / Time (UTC)" "Type"
echo "────────────────────────────────────────────────────────────────────"

for i in $(seq 0 $((DISPLAY_COUNT - 1))); do
  SNAP_DATE=$(echo "$SORTED_SNAPS" | jq -r ".[$i].date")
  IS_OD=$(echo "$SORTED_SNAPS"     | jq -r ".[$i].isOnDemandSnapshot")
  if [[ "$IS_OD" == "true" ]]; then
    SNAP_TYPE="On-demand"
  else
    SNAP_TYPE="Scheduled"
  fi
  printf "  %-4s %-30s %s\n" "$((i + 1))" "$SNAP_DATE" "$SNAP_TYPE"
done

echo "────────────────────────────────────────────────────────────────────"
echo ""
read -rp "Select snapshot to restore from (number): " SNAP_SEL

if ! [[ "$SNAP_SEL" =~ ^[0-9]+$ ]] || (( SNAP_SEL < 1 || SNAP_SEL > DISPLAY_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

SNAP_IDX=$((SNAP_SEL - 1))
SNAP_ID=$(echo "$SORTED_SNAPS"   | jq -r ".[$SNAP_IDX].id")
SNAP_DATE=$(echo "$SORTED_SNAPS" | jq -r ".[$SNAP_IDX].date")

# ==============================================================================
# 4. CONFIRM — restore is destructive (overwrites the running VM)
# ==============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  ⚠  RESTORE CONFIRMATION"
echo "══════════════════════════════════════════════════════════════════"
echo "  VM       : $VM_NAME"
echo "  Cluster  : $CLUSTER_NAME"
echo "  Snapshot : $SNAP_DATE"
echo "  Type     : In-place recovery (overwrites the existing VM)"
echo "══════════════════════════════════════════════════════════════════"
echo ""
read -rp "Type YES to confirm and start the restore: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Restore cancelled."
  exit 0
fi

# ==============================================================================
# 5. INITIATE IN-PLACE RECOVERY
# ==============================================================================
echo ""
echo "Initiating restore..."

RESTORE_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RESTORE_MUTATION="mutation {
  vsphereVmInitiateInPlaceRecovery(input: {
    id: \"$VM_ID\"
    config: {
      requiredRecoveryParameters: {
        snapshotId: \"$SNAP_ID\"
      }
    }
  }) {
    id
    status
    startTime
    progress
    error { message }
  }
}"

RESTORE_RESPONSE=$(rsc_query "$RESTORE_MUTATION")

JOB_ID=$(echo "$RESTORE_RESPONSE" | jq -r '.data.vsphereVmInitiateInPlaceRecovery.id // empty')

if [[ -z "$JOB_ID" ]]; then
  echo "Error: Failed to initiate restore." >&2
  echo "$RESTORE_RESPONSE" | jq '.' >&2
  exit 1
fi

echo "-> Restore job started. Job ID: $JOB_ID"
echo ""

# ==============================================================================
# 6. MONITOR — poll activitySeriesConnection for status and event messages
#
# Note: vSphereVMAsyncRequestStatus does not support INPLACE_EXPORT job IDs.
# activitySeriesConnection is the authoritative source for restore job status.
# Terminal states from ActivityStatusEnum: Success, TaskSuccess, Failure,
# TaskFailure, Canceled.
# ==============================================================================
echo "Monitoring restore progress (polling every 15s)..."
echo "────────────────────────────────────────────────────────────────────"

LAST_LINE=""
POLL_INTERVAL=15

while true; do

  TIMESTAMP=$(date '+%H:%M:%S')

  # --- Primary: activitySeriesConnection ---
  ACTIVITY_QUERY="query {
    activitySeriesConnection(filters: {
      objectFid: \"$VM_ID\"
      lastActivityType: [Recovery]
      lastUpdatedTimeGt: \"$RESTORE_START_TIME\"
    }) {
      nodes {
        lastActivityMessage
        progress
        severity
        failureReason
        causeErrorMessage
        activityConnection(first: 1) {
          nodes {
            status
            message
          }
        }
      }
    }
  }"

  ACTIVITY_RESP=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$ACTIVITY_QUERY" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  # Null-safe extractions — default to empty/zero if no activity yet
  NODES=$(echo "$ACTIVITY_RESP" | jq '(.data.activitySeriesConnection.nodes // []) | first // {}')

  ACT_STATUS=$(echo "$NODES"  | jq -r '(.activityConnection.nodes // []) | first | .status // "Queued"')
  ACT_MSG=$(echo "$NODES"     | jq -r '.lastActivityMessage // ""')
  ACT_PROGRESS=$(echo "$NODES"| jq -r '.progress // 0')
  ACT_ERROR=$(echo "$NODES"   | jq -r '.failureReason // .causeErrorMessage // ""')

  PROGRESS_INT=$(echo "$ACT_PROGRESS" | awk '{printf "%d", $1}')

  # --- Secondary: vSphereVMAsyncRequestStatus (best-effort, non-fatal) ---
  ASYNC_RESP=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "query { vSphereVMAsyncRequestStatus(id: \"$JOB_ID\" clusterUuid: \"$CLUSTER_ID\") { status progress endTime startTime error { message } } }" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  ASYNC_STATUS=$(echo "$ASYNC_RESP"  | jq -r '.data.vSphereVMAsyncRequestStatus.status   // ""')
  ASYNC_END=$(echo "$ASYNC_RESP"     | jq -r '.data.vSphereVMAsyncRequestStatus.endTime   // "-"')
  ASYNC_START=$(echo "$ASYNC_RESP"   | jq -r '.data.vSphereVMAsyncRequestStatus.startTime // "-"')

  # Use async progress if activity hasn't reported yet
  if [[ "$PROGRESS_INT" -eq 0 && -n "$ASYNC_STATUS" ]]; then
    ASYNC_PROG=$(echo "$ASYNC_RESP" | jq -r '.data.vSphereVMAsyncRequestStatus.progress // 0')
    PROGRESS_INT=$(echo "$ASYNC_PROG" | awk '{printf "%d", $1}')
  fi

  # --- Determine effective status (activity is authoritative) ---
  case "$ACT_STATUS" in
    Success|TaskSuccess)   EFF_STATUS="SUCCEEDED" ;;
    Failure|TaskFailure)   EFF_STATUS="FAILED" ;;
    Canceled|Canceling)    EFF_STATUS="CANCELED" ;;
    Running)               EFF_STATUS="RUNNING" ;;
    Queued)                EFF_STATUS="QUEUED" ;;
    *)
      # Fall back to async status if activity not yet available
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

  # --- Build display line ---
  case "$EFF_STATUS" in
    QUEUED)    STATUS_LABEL="Queued" ;;
    RUNNING)   STATUS_LABEL="Restoring... ${PROGRESS_INT}%" ;;
    SUCCEEDED) STATUS_LABEL="Restore complete" ;;
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

  # --- Check terminal states ---
  case "$EFF_STATUS" in
    SUCCEEDED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Restore completed successfully."
      echo "  VM         : $VM_NAME"
      echo "  Snapshot   : $SNAP_DATE"
      echo "  Cluster    : $CLUSTER_NAME"
      echo "  Start time : ${ASYNC_START:--}"
      echo "  End time   : ${ASYNC_END:--}"
      echo "  Job ID     : $JOB_ID"
      exit 0
      ;;
    FAILED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Restore failed." >&2
      echo "  VM     : $VM_NAME" >&2
      echo "  Error  : ${ACT_ERROR:-$ACT_MSG}" >&2
      echo "  Job ID : $JOB_ID" >&2
      exit 1
      ;;
    CANCELED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "Restore was canceled." >&2
      echo "  VM     : $VM_NAME" >&2
      echo "  Job ID : $JOB_ID" >&2
      exit 1
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
