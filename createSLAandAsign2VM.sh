#!/bin/bash
# ==============================================================================
# createSLAandAsign2VM.sh
#
# Description:
#   Creates a new SLA domain (or reuses one with the same name if it already
#   exists) and assigns it to a specific VM. Both the SLA name and VM name are
#   entered interactively.
#
# Flow:
#   1. Prompt for SLA name and VM name
#   2. Search RSC for an existing SLA with that exact name
#   3. If not found: create a new global SLA (daily, 7-day retention)
#   4. Find the VM by name in the vSphere inventory
#   5. Assign the SLA to the VM
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash createSLAandAsign2VM.sh
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
# 1. AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. PROMPT FOR NAMES
# ==============================================================================
echo ""
read -rp "SLA name: " NEW_SLA_NAME
read -rp "VM name:  " TARGET_VM_NAME

if [[ -z "$NEW_SLA_NAME" || -z "$TARGET_VM_NAME" ]]; then
  echo "Error: SLA name and VM name are required." >&2; exit 1
fi

# ==============================================================================
# 3. FIND OR CREATE SLA DOMAIN
# ==============================================================================
echo ""
echo "Searching for SLA '$NEW_SLA_NAME'..."

SLA_SEARCH=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "query { slaDomains(filter: {field: NAME text: \"$NEW_SLA_NAME\"}) { nodes { id name } } }" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

NEW_SLA_ID=$(echo "$SLA_SEARCH" | jq -r --arg name "$NEW_SLA_NAME" \
  '.data.slaDomains.nodes[] | select(.name == $name) | .id' | head -n 1)

if [[ -n "$NEW_SLA_ID" ]]; then
  echo "-> Found existing SLA '$NEW_SLA_NAME'. ID: $NEW_SLA_ID"
else
  echo "-> SLA not found. Creating '$NEW_SLA_NAME'..."

  CREATE_MUTATION="mutation {
    createGlobalSla(input: {
      name: \"$NEW_SLA_NAME\"
      objectTypes: [VSPHERE_OBJECT_TYPE]
      snapshotSchedule: {
        daily: {
          basicSchedule: { frequency: 1 retention: 7 retentionUnit: DAYS }
        }
      }
    }) { id name }
  }"

  SLA_RESPONSE=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$CREATE_MUTATION" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")

  if echo "$SLA_RESPONSE" | jq -e '.errors' &>/dev/null; then
    echo "Error: Failed to create SLA:" >&2
    echo "$SLA_RESPONSE" | jq '.errors' >&2
    exit 1
  fi

  NEW_SLA_ID=$(echo "$SLA_RESPONSE" | jq -r '.data.createGlobalSla.id // empty')

  if [[ -z "$NEW_SLA_ID" ]]; then
    echo "Error: SLA creation returned no ID." >&2
    echo "$SLA_RESPONSE" | jq '.' >&2
    exit 1
  fi
  echo "-> SLA created. ID: $NEW_SLA_ID"
fi

# ==============================================================================
# 4. FIND VM BY NAME
# ==============================================================================
echo ""
echo "Searching for VM '$TARGET_VM_NAME'..."

VM_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "query { vSphereVmNewConnection(filter: [{field: NAME texts: \"$TARGET_VM_NAME\"}]) { nodes { id name } } }" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

VM_ID=$(echo "$VM_RESPONSE" | jq -r '.data.vSphereVmNewConnection.nodes[0].id // empty')

if [[ -z "$VM_ID" ]]; then
  echo "Error: VM '$TARGET_VM_NAME' not found in RSC inventory." >&2
  exit 1
fi
echo "-> VM found. ID: $VM_ID"

# ==============================================================================
# 5. ASSIGN SLA TO VM
# ==============================================================================
echo ""
echo "Assigning SLA '$NEW_SLA_NAME' to VM '$TARGET_VM_NAME'..."

ASSIGN_MUTATION="mutation {
  assignSla(input: {
    slaDomainAssignType: protectWithSlaId
    slaOptionalId: \"$NEW_SLA_ID\"
    objectIds: [\"$VM_ID\"]
  }) { success }
}"

ASSIGN_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "$ASSIGN_MUTATION" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

SUCCESS=$(echo "$ASSIGN_RESPONSE" | jq -r '.data.assignSla.success // "false"')

if [[ "$SUCCESS" == "true" ]]; then
  echo ""
  echo "Done. VM '$TARGET_VM_NAME' is now protected by SLA '$NEW_SLA_NAME'."
else
  echo "Error: SLA assignment failed." >&2
  echo "$ASSIGN_RESPONSE" | jq '.' >&2
  exit 1
fi
