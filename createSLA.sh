#!/bin/bash
# ==============================================================================
# createSLA.sh
#
# Description:
#   Creates a new global SLA domain for vSphere and MSSQL object types with a
#   daily backup schedule (1x per day, 7-day retention). Prompts interactively
#   for the SLA name.
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - rsc_auth.sh in the same directory (shared token cache)
#
# Usage:
#   bash createSLA.sh
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
# PROMPT FOR SLA NAME
# ==============================================================================
echo ""
read -rp "Enter SLA name: " SLA_NAME

if [[ -z "$SLA_NAME" ]]; then
  echo "Error: SLA name cannot be empty." >&2; exit 1
fi

# ==============================================================================
# CREATE SLA DOMAIN
# ==============================================================================
echo ""
echo "Creating SLA domain '$SLA_NAME'..."

MUTATION="mutation {
  createGlobalSla(input: {
    name: \"$SLA_NAME\"
    objectTypes: [VSPHERE_OBJECT_TYPE, MSSQL_OBJECT_TYPE]
    snapshotSchedule: {
      daily: {
        basicSchedule: { frequency: 1 retention: 7 retentionUnit: DAYS }
      }
    }
  }) {
    name
    id
  }
}"

RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$(jq -n --arg q "$MUTATION" '{query: $q}')" \
  "https://$RSC_FQDN/api/graphql")

if echo "$RESPONSE" | jq -e '.errors' &>/dev/null; then
  echo "Error: API returned errors:" >&2
  echo "$RESPONSE" | jq '.errors' >&2
  exit 1
fi

SLA_ID=$(echo "$RESPONSE" | jq -r '.data.createGlobalSla.id // empty')

if [[ -z "$SLA_ID" ]]; then
  echo "Error: SLA creation failed — no ID returned." >&2
  echo "$RESPONSE" | jq '.' >&2
  exit 1
fi

echo "SLA domain created successfully."
echo "$RESPONSE" | jq '.data.createGlobalSla'
