#!/bin/bash
# ==============================================================================
# filerestoreVM.sh
#
# Description:
#   Interactively browses a VMware vSphere VM snapshot file system and restores
#   selected files and/or directories to a /restore folder on the source VM,
#   preserving the original path structure.
#
# Flow:
#   1. List all VMs — user selects one by number
#   2. List all snapshots (newest first) — user selects one by number
#   3. Interactive file browser (tree walk) — navigate and select items
#   4. Confirm selection
#   5. Attempt restore via RBS (Rubrik Backup Service — no credentials needed)
#      If RBS is not installed on the VM: prompt for guest OS credentials, retry
#   6. Stream activity events until restore completes
#
# File browser commands:
#   <number>    Enter directory / toggle file selection
#   s <number>  Select/deselect any item (file or directory)
#   s .         Select the current directory itself
#   ..          Go up one level
#   ls          List currently selected items
#   done        Proceed to restore
#   q           Quit without restoring
#
# Restore destination:
#   Windows VMs: /C:/Files/report.docx  ->  C:/restore/Files/report.docx
#   Linux VMs:   /etc/passwd            ->  /restore/etc/passwd
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash filerestoreVM.sh
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
    echo "API error:" >&2
    echo "$response" | jq '.errors' >&2
    exit 1
  fi
  echo "$response"
}

# Like gql_vars but returns the raw response even on errors (for retry logic).
gql_vars_raw() {
  curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')" \
    "https://$RSC_FQDN/api/graphql"
}

gql_vars() {
  local response
  response=$(gql_vars_raw "$1" "$2")
  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "API error:" >&2
    echo "$response" | jq '.errors' >&2
    exit 1
  fi
  echo "$response"
}

format_size() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}"
  elif [[ "$bytes" -ge 1048576 ]]; then
    awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
  elif [[ "$bytes" -ge 1024 ]]; then
    awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
  else
    echo "${bytes} B"
  fi
}

# Returns the restore destination directory for a given source path.
# Windows paths (/C:/foo/bar) map to C:/restore/foo
# Linux paths (/etc/foo) map to /restore/etc
get_restore_path() {
  local fpath="$1"
  if [[ "$fpath" =~ ^/([A-Za-z]):(/.+)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local dir_part
    dir_part=$(dirname "${BASH_REMATCH[2]}")
    if [[ "$dir_part" == "/" || "$dir_part" == "." ]]; then
      echo "${drive}:/restore"
    else
      echo "${drive}:/restore${dir_part}"
    fi
  elif [[ "$fpath" =~ ^/([A-Za-z]):/?$ ]]; then
    echo "${BASH_REMATCH[1]}:/restore"
  else
    local dir_part
    dir_part=$(dirname "$fpath")
    if [[ "$dir_part" == "/" || "$dir_part" == "." ]]; then
      echo "/restore"
    else
      echo "/restore${dir_part}"
    fi
  fi
}

# ==============================================================================
# 1. AUTHENTICATE
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. LIST ALL VMs
# ==============================================================================
echo ""
echo "Fetching VM inventory..."

VM_RESP=$(gql "query {
  vSphereVmNewConnection(filter: [
    {field: IS_RELIC texts: \"false\"},
    {field: IS_REPLICATED texts: \"false\"}
  ]) {
    nodes {
      id name
      cluster { id name }
      effectiveSlaDomain { name }
      powerStatus
    }
  }
}")

VM_COUNT=$(echo "$VM_RESP" | jq '.data.vSphereVmNewConnection.nodes | length')
if [[ "$VM_COUNT" -eq 0 ]]; then echo "Error: No VMs found." >&2; exit 1; fi

echo ""
echo "Available VMs:"
echo "────────────────────────────────────────────────────────────────────"
printf "  %-4s %-38s %-18s %s\n" "No." "VM Name" "SLA" "Power"
echo "────────────────────────────────────────────────────────────────────"
for i in $(seq 0 $((VM_COUNT - 1))); do
  printf "  %-4s %-38s %-18s %s\n" "$((i+1))" \
    "$(echo "$VM_RESP" | jq -r ".data.vSphereVmNewConnection.nodes[$i].name")" \
    "$(echo "$VM_RESP" | jq -r ".data.vSphereVmNewConnection.nodes[$i].effectiveSlaDomain.name")" \
    "$(echo "$VM_RESP" | jq -r ".data.vSphereVmNewConnection.nodes[$i].powerStatus // \"-\"")"
done
echo "────────────────────────────────────────────────────────────────────"
echo ""
read -rp "Select VM (number): " VM_SEL

if ! [[ "$VM_SEL" =~ ^[0-9]+$ ]] || (( VM_SEL < 1 || VM_SEL > VM_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

IDX=$((VM_SEL - 1))
VM_ID=$(echo "$VM_RESP"       | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].id")
VM_NAME=$(echo "$VM_RESP"     | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].name")
CLUSTER_ID=$(echo "$VM_RESP"  | jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.id")
CLUSTER_NAME=$(echo "$VM_RESP"| jq -r ".data.vSphereVmNewConnection.nodes[$IDX].cluster.name")

# ==============================================================================
# 3. LIST SNAPSHOTS (newest first, max 30)
# ==============================================================================
echo ""
echo "Fetching snapshots for: $VM_NAME ..."

SNAP_RESP=$(gql "query { vSphereVmNew(fid: \"$VM_ID\") {
  snapshotConnection { nodes { id date isOnDemandSnapshot } }
}}")

SNAP_COUNT=$(echo "$SNAP_RESP" | jq '.data.vSphereVmNew.snapshotConnection.nodes | length')
if [[ "$SNAP_COUNT" -eq 0 ]]; then echo "Error: No snapshots found." >&2; exit 1; fi

DISPLAY_COUNT=$SNAP_COUNT
(( DISPLAY_COUNT > 30 )) && DISPLAY_COUNT=30

SORTED_SNAPS=$(echo "$SNAP_RESP" | jq '
  [.data.vSphereVmNew.snapshotConnection.nodes[] | {id, date, isOnDemandSnapshot}]
  | sort_by(.date) | reverse')

echo ""
echo "Snapshots (showing $DISPLAY_COUNT of $SNAP_COUNT, newest first):"
echo "────────────────────────────────────────────────────────────────────"
printf "  %-4s %-30s %s\n" "No." "Date / Time (UTC)" "Type"
echo "────────────────────────────────────────────────────────────────────"
for i in $(seq 0 $((DISPLAY_COUNT - 1))); do
  IS_OD=$(echo "$SORTED_SNAPS" | jq -r ".[$i].isOnDemandSnapshot")
  [[ "$IS_OD" == "true" ]] && STYPE="On-demand" || STYPE="Scheduled"
  printf "  %-4s %-30s %s\n" "$((i+1))" \
    "$(echo "$SORTED_SNAPS" | jq -r ".[$i].date")" "$STYPE"
done
echo "────────────────────────────────────────────────────────────────────"
echo ""
read -rp "Select snapshot (number): " SNAP_SEL

if ! [[ "$SNAP_SEL" =~ ^[0-9]+$ ]] || (( SNAP_SEL < 1 || SNAP_SEL > DISPLAY_COUNT )); then
  echo "Error: Invalid selection." >&2; exit 1
fi

SNAP_IDX=$((SNAP_SEL - 1))
SNAP_ID=$(echo "$SORTED_SNAPS"   | jq -r ".[$SNAP_IDX].id")
SNAP_DATE=$(echo "$SORTED_SNAPS" | jq -r ".[$SNAP_IDX].date")

# ==============================================================================
# 4. INTERACTIVE FILE BROWSER
# ==============================================================================
CURRENT_PATH="/"
declare -a SELECTED_PATHS=()

browse_dir() {
  local path="$1"
  gql "query {
    browseSnapshotFileConnection(
      snapshotFid: \"$SNAP_ID\"
      path: \"$path\"
      first: 100
    ) {
      edges { node {
        filename absolutePath fileMode size lastModified
      }}
      pageInfo { hasNextPage }
    }
  }"
}

is_selected() {
  local target="$1"
  for p in "${SELECTED_PATHS[@]+"${SELECTED_PATHS[@]}"}"; do
    [[ "$p" == "$target" ]] && return 0
  done
  return 1
}

toggle_selection() {
  local target="$1"
  local new_list=()
  local removed=false
  for p in "${SELECTED_PATHS[@]+"${SELECTED_PATHS[@]}"}"; do
    if [[ "$p" == "$target" ]]; then
      removed=true
    else
      new_list+=("$p")
    fi
  done
  if $removed; then
    SELECTED_PATHS=("${new_list[@]+"${new_list[@]}"}")
    echo "  -> Deselected: $target"
  else
    SELECTED_PATHS+=("$target")
    echo "  -> Selected:   $target"
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  File Browser — $VM_NAME"
printf "║  Snapshot: %-57s║\n" "$SNAP_DATE"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Commands: <number> enter dir | s <number> select | s . select dir"
echo "            .. go up | ls list selected | done proceed | q quit"

while true; do
  echo ""
  echo "  Path: $CURRENT_PATH"
  echo "  ──────────────────────────────────────────────────────────────────"

  DIR_RESP=$(browse_dir "$CURRENT_PATH")
  ITEMS=$(echo "$DIR_RESP" | jq '[.data.browseSnapshotFileConnection.edges[].node]')
  ITEM_COUNT=$(echo "$ITEMS" | jq 'length')
  HAS_NEXT=$(echo "$DIR_RESP" | jq -r '.data.browseSnapshotFileConnection.pageInfo.hasNextPage')

  if [[ "$ITEM_COUNT" -eq 0 ]]; then
    echo "  (empty directory)"
  else
    printf "  %-4s %-6s %-42s %-10s %s\n" "No." "Type" "Name" "Size" "Modified"
    echo "  ──────────────────────────────────────────────────────────────────"
    for i in $(seq 0 $((ITEM_COUNT - 1))); do
      FNAME=$(echo "$ITEMS"   | jq -r ".[$i].filename")
      FMODE=$(echo "$ITEMS"   | jq -r ".[$i].fileMode")
      FSIZE=$(echo "$ITEMS"   | jq -r ".[$i].size // 0")
      FMOD=$(echo "$ITEMS"    | jq -r ".[$i].lastModified // \"\"" | cut -c1-10)
      FPATH=$(echo "$ITEMS"   | jq -r ".[$i].absolutePath")

      [[ "$FMODE" == "DIRECTORY" ]] && FTYPE="[DIR]" || FTYPE="[FILE]"
      is_selected "$FPATH" && MARK="*" || MARK=" "
      FSIZE_FMT=$(format_size "$FSIZE")
      printf "  %s%-4s %-6s %-42s %-10s %s\n" "$MARK" "$((i+1))" "$FTYPE" "$FNAME" "$FSIZE_FMT" "$FMOD"
    done
    [[ "$HAS_NEXT" == "true" ]] && echo "  (more items exist — only first 100 shown)"
  fi

  echo "  ──────────────────────────────────────────────────────────────────"
  SEL_COUNT=${#SELECTED_PATHS[@]}
  echo "  Selected: $SEL_COUNT item(s) | * = marked for restore"
  echo ""
  read -rp "  > " CMD

  # Plain number — navigate or toggle file
  if [[ "$CMD" =~ ^[0-9]+$ ]]; then
    NUM=$CMD
    if (( NUM < 1 || NUM > ITEM_COUNT )); then
      echo "  Error: Number out of range."
      continue
    fi
    IDX2=$((NUM - 1))
    FMODE=$(echo "$ITEMS" | jq -r ".[$IDX2].fileMode")
    FPATH=$(echo "$ITEMS" | jq -r ".[$IDX2].absolutePath")
    if [[ "$FMODE" == "DIRECTORY" ]]; then
      CURRENT_PATH="$FPATH"
    else
      toggle_selection "$FPATH"
    fi
    continue
  fi

  # s <number> — select item
  if [[ "$CMD" =~ ^s\ +([0-9]+)$ ]]; then
    NUM="${BASH_REMATCH[1]}"
    if (( NUM < 1 || NUM > ITEM_COUNT )); then
      echo "  Error: Number out of range."
      continue
    fi
    FPATH=$(echo "$ITEMS" | jq -r ".[${NUM}-1].absolutePath")
    toggle_selection "$FPATH"
    continue
  fi

  # s . — select current directory
  if [[ "$CMD" == "s ." || "$CMD" == "s." ]]; then
    toggle_selection "$CURRENT_PATH"
    continue
  fi

  # .. — go up
  if [[ "$CMD" == ".." ]]; then
    if [[ "$CURRENT_PATH" == "/" ]]; then
      echo "  Already at root."
    else
      CURRENT_PATH=$(dirname "$CURRENT_PATH")
      [[ -z "$CURRENT_PATH" ]] && CURRENT_PATH="/"
    fi
    continue
  fi

  # ls — list selected
  if [[ "$CMD" == "ls" ]]; then
    if [[ ${#SELECTED_PATHS[@]} -eq 0 ]]; then
      echo "  No items selected."
    else
      echo "  Selected items:"
      for p in "${SELECTED_PATHS[@]}"; do
        echo "    $p  ->  $(get_restore_path "$p")/$(basename "$p")"
      done
    fi
    continue
  fi

  # done — proceed
  if [[ "$CMD" == "done" ]]; then
    if [[ ${#SELECTED_PATHS[@]} -eq 0 ]]; then
      echo "  No items selected. Select at least one file or directory."
      continue
    fi
    break
  fi

  # q — quit
  if [[ "$CMD" == "q" ]]; then
    echo ""
    echo "Cancelled."
    exit 0
  fi

  echo "  Unknown command. Use a number, s <number>, s ., .., ls, done, or q."
done

# ==============================================================================
# 5. CONFIRM
# ==============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  FILE RESTORE CONFIRMATION"
echo "══════════════════════════════════════════════════════════════════"
echo "  VM         : $VM_NAME"
echo "  Cluster    : $CLUSTER_NAME"
echo "  Snapshot   : $SNAP_DATE"
echo ""
echo "  Items to restore:"
for p in "${SELECTED_PATHS[@]}"; do
  echo "    $p  ->  $(get_restore_path "$p")/$(basename "$p")"
done
echo "══════════════════════════════════════════════════════════════════"
echo ""
read -rp "Type YES to confirm and start the restore: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Restore cancelled."
  exit 0
fi

# ==============================================================================
# 6. BUILD RESTORE PAYLOAD AND EXECUTE
#
# Strategy: try RBS (Rubrik Backup Service) first — no credentials needed.
# If RSC responds with RBK20100125 (guest OS credentials required), RBS is
# not installed on this VM. Prompt for credentials and retry once.
# ==============================================================================
echo ""
echo "Initiating file restore..."

RESTORE_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RESTORE_START_EPOCH=$(date +%s)

# Build restoreConfig JSON array — one entry per selected path
RESTORE_CONFIG="[]"
for p in "${SELECTED_PATHS[@]}"; do
  DEST_DIR=$(get_restore_path "$p")
  RESTORE_CONFIG=$(echo "$RESTORE_CONFIG" | jq \
    --arg path "$p" --arg rpath "$DEST_DIR" \
    '. + [{"restorePathPair": {"path": $path, "restorePath": $rpath}}]')
done

MUTATION="mutation RecoverFiles(\$input: VsphereVmRecoverFilesNewInput!) {
  vsphereVmRecoverFilesNew(input: \$input) { id }
}"

# First attempt — RBS (no guest credentials)
VARIABLES=$(jq -n \
  --arg snapId    "$SNAP_ID" \
  --arg clusterId "$CLUSTER_ID" \
  --arg vmId      "$VM_ID" \
  --argjson cfg   "$RESTORE_CONFIG" \
  '{input: {
    id:          $snapId,
    clusterUuid: $clusterId,
    config: {
      destObjectId:   $vmId,
      shouldUseAgent: true,
      restoreConfig:  $cfg
    }
  }}')

echo "-> Trying RBS (Rubrik Backup Service)..."
RESTORE_RESP=$(gql_vars_raw "$MUTATION" "$VARIABLES")

# Check whether the response is a credentials error (RBS not installed)
if echo "$RESTORE_RESP" | jq -e '.errors' &>/dev/null; then
  ERR_MSG=$(echo "$RESTORE_RESP" | jq -r '.errors[0].message // ""')

  if echo "$ERR_MSG" | grep -qi "RBK20100125\|Guest OS credentials"; then
    echo "-> RBS is not installed on this VM."
    echo ""
    echo "Falling back to guest OS credentials..."
    read -rp  "  Username (e.g. Administrator or DOMAIN\\user): " GUEST_USER
    read -rsp "  Password: " GUEST_PASS
    echo ""

    if [[ -z "$GUEST_USER" || -z "$GUEST_PASS" ]]; then
      echo "Error: Username and password are required." >&2; exit 1
    fi

    # Retry with guest credentials
    VARIABLES=$(jq -n \
      --arg snapId    "$SNAP_ID" \
      --arg clusterId "$CLUSTER_ID" \
      --arg vmId      "$VM_ID" \
      --arg user      "$GUEST_USER" \
      --arg pass      "$GUEST_PASS" \
      --argjson cfg   "$RESTORE_CONFIG" \
      '{input: {
        id:          $snapId,
        clusterUuid: $clusterId,
        config: {
          destObjectId:     $vmId,
          shouldUseAgent:   true,
          restoreConfig:    $cfg,
          guestCredentials: { username: $user, password: $pass }
        }
      }}')

    RESTORE_RESP=$(gql_vars "$MUTATION" "$VARIABLES")
  else
    # Different error — not credentials related, fail immediately
    echo "API error:" >&2
    echo "$RESTORE_RESP" | jq '.errors' >&2
    exit 1
  fi
fi

JOB_ID=$(echo "$RESTORE_RESP" | jq -r '.data.vsphereVmRecoverFilesNew.id // empty')

if [[ -z "$JOB_ID" ]]; then
  echo "Error: Failed to initiate file restore." >&2
  echo "$RESTORE_RESP" | jq '.' >&2
  exit 1
fi

echo "-> File restore job started. Job ID: $JOB_ID"
echo ""

# ==============================================================================
# 7. MONITOR — activitySeriesConnection (same pattern as restoreVM.sh)
# ==============================================================================
echo "Monitoring restore progress (polling every 15s)..."
echo "Note: file restore progress stays at 0% throughout — this is normal."
echo "      Rubrik does not report per-file copy progress via the activity API."
echo "────────────────────────────────────────────────────────────────────"

# Determine restore base for the summary (OS-aware)
FIRST_PATH="${SELECTED_PATHS[0]}"
if [[ "$FIRST_PATH" =~ ^/([A-Za-z]):/ ]]; then
  RESTORE_BASE="${BASH_REMATCH[1]}:/restore"
else
  RESTORE_BASE="/restore"
fi

LAST_LINE=""
POLL_INTERVAL=15

while true; do

  TIMESTAMP=$(date '+%H:%M:%S')

  ACTIVITY_RESP=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "query {
      activitySeriesConnection(filters: {
        objectFid: \"$VM_ID\"
        lastActivityType: [Recovery, LocalRecovery]
        lastUpdatedTimeGt: \"$RESTORE_START_TIME\"
      }) {
        nodes {
          lastActivityMessage
          progress
          severity
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

  case "$ACT_STATUS" in
    Success|TaskSuccess)   EFF_STATUS="SUCCEEDED" ;;
    Failure|TaskFailure)   EFF_STATUS="FAILED"    ;;
    Canceled|Canceling)    EFF_STATUS="CANCELED"  ;;
    Running)               EFF_STATUS="RUNNING"   ;;
    *)                     EFF_STATUS="RUNNING"   ;;
  esac

  case "$EFF_STATUS" in
    RUNNING)   STATUS_LABEL="Restoring files... ${PROGRESS_INT}%" ;;
    SUCCEEDED) STATUS_LABEL="File restore complete" ;;
    FAILED)    STATUS_LABEL="Failed" ;;
    CANCELED)  STATUS_LABEL="Canceled" ;;
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
      echo "File restore completed successfully."
      echo "  VM       : $VM_NAME"
      echo "  Cluster  : $CLUSTER_NAME"
      echo "  Snapshot : $SNAP_DATE"
      echo "  Duration : $DURATION_FMT"
      echo "  Job ID   : $JOB_ID"
      echo ""
      echo "  Restored items (source  ->  destination on $VM_NAME):"
      for p in "${SELECTED_PATHS[@]}"; do
        echo "    $p"
        echo "      ->  $(get_restore_path "$p")/$(basename "$p")"
      done
      exit 0
      ;;
    FAILED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "File restore failed." >&2
      echo "  VM     : $VM_NAME" >&2
      echo "  Error  : ${ACT_ERROR:-$ACT_MSG}" >&2
      echo "  Job ID : $JOB_ID" >&2
      exit 1
      ;;
    CANCELED)
      echo "────────────────────────────────────────────────────────────────────"
      echo ""
      echo "File restore was canceled." >&2
      echo "  VM     : $VM_NAME" >&2
      echo "  Job ID : $JOB_ID" >&2
      exit 1
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
