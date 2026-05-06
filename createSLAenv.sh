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

# Authenticate (uses cached token when still valid)
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# Prompt for SLA name
read -rp "Enter SLA name: " SLA_NAME
if [[ -z "$SLA_NAME" ]]; then
  echo "Error: SLA name cannot be empty." >&2
  exit 1
fi

# Create global SLA domain
query="mutation createSla { createGlobalSla(input: { name: \\\"$SLA_NAME\\\" objectTypes: [VSPHERE_OBJECT_TYPE MSSQL_OBJECT_TYPE] snapshotSchedule: { daily: { basicSchedule: { frequency: 1 retention: 7 retentionUnit: DAYS } } } }) { name id } }"

RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "{\"query\": \"$query\"}" \
  "https://$RSC_FQDN/api/graphql")

echo "$RESPONSE" | jq .
