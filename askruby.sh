#!/bin/bash
# ==============================================================================
# askruby.sh
#
# Description:
#   Sends a natural-language question to Ruby, Rubrik's AI assistant, via the
#   RSC Annapurna API, and displays the answer with source references.
#
# How it works:
#   1. Queries the RSC GraphQL API to list available Ruby chatbots (retrievers).
#   2. If more than one chatbot exists, prompts the user to choose one.
#   3. Prompts the user for a question.
#   4. POSTs the question to the Annapurna REST endpoint:
#        POST https://<tenant>/api/annapurna/<chatbot-id>/retrieve
#   5. Displays each result with its content and source URL.
#
# Requirements:
#   - curl, jq
#   - .env file with RSC credentials (same directory as this script)
#   - RSC tenant must have the Annapurna / Ruby AI feature licensed and enabled.
#     If not enabled, the chatbots query will return a 403 error.
#
# Usage:
#   bash askruby.sh
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
# 1. AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1

# ==============================================================================
# 2. LIST AVAILABLE RUBY CHATBOTS
# ==============================================================================
echo ""
echo "Fetching available Ruby chatbots..."

CHATBOTS_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d '{"query": "query { chatbots { nodes { name id } } }"}' \
  "https://$RSC_FQDN/api/graphql")

# Check for feature-not-enabled error
if echo "$CHATBOTS_RESPONSE" | jq -e '.errors' &>/dev/null; then
  ERROR_MSG=$(echo "$CHATBOTS_RESPONSE" | jq -r '.errors[0].message')
  echo "" >&2
  echo "Error: Could not access Ruby chatbots." >&2
  echo "Reason: $ERROR_MSG" >&2
  echo "" >&2
  echo "The Annapurna / Ruby AI feature must be licensed and enabled on this RSC tenant." >&2
  exit 1
fi

CHATBOT_COUNT=$(echo "$CHATBOTS_RESPONSE" | jq '.data.chatbots.nodes | length')

if [[ "$CHATBOT_COUNT" -eq 0 ]]; then
  echo "Error: No Ruby chatbots found on this RSC tenant." >&2
  echo "       Ask your Rubrik administrator to configure an Annapurna chatbot." >&2
  exit 1
fi

# ==============================================================================
# 3. SELECT CHATBOT (auto-select if only one exists)
# ==============================================================================
if [[ "$CHATBOT_COUNT" -eq 1 ]]; then
  CHATBOT_ID=$(echo "$CHATBOTS_RESPONSE"   | jq -r '.data.chatbots.nodes[0].id')
  CHATBOT_NAME=$(echo "$CHATBOTS_RESPONSE" | jq -r '.data.chatbots.nodes[0].name')
  echo "-> Using chatbot: $CHATBOT_NAME"
else
  echo ""
  echo "Available Ruby chatbots:"
  echo "--------------------------------------"
  for i in $(seq 0 $((CHATBOT_COUNT - 1))); do
    NAME=$(echo "$CHATBOTS_RESPONSE" | jq -r ".data.chatbots.nodes[$i].name")
    printf "  %s) %s\n" "$((i + 1))" "$NAME"
  done
  echo "--------------------------------------"
  echo ""
  read -rp "Select chatbot number: " SELECTION

  if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || (( SELECTION < 1 || SELECTION > CHATBOT_COUNT )); then
    echo "Error: Invalid selection." >&2; exit 1
  fi

  IDX=$((SELECTION - 1))
  CHATBOT_ID=$(echo "$CHATBOTS_RESPONSE"   | jq -r ".data.chatbots.nodes[$IDX].id")
  CHATBOT_NAME=$(echo "$CHATBOTS_RESPONSE" | jq -r ".data.chatbots.nodes[$IDX].name")
fi

# ==============================================================================
# 4. PROMPT FOR QUESTION
# ==============================================================================
echo ""
read -rp "Ask Ruby: " QUESTION

if [[ -z "$QUESTION" ]]; then
  echo "Error: Question cannot be empty." >&2; exit 1
fi

# ==============================================================================
# 5. SEND QUESTION TO RUBY
# ==============================================================================
echo ""
echo "Asking Ruby..."

PAYLOAD=$(jq -n --arg q "$QUESTION" '{"query": $q}')

RETRIEVE_RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$PAYLOAD" \
  "https://$RSC_FQDN/api/annapurna/$CHATBOT_ID/retrieve")

# Validate response
RESULT_COUNT=$(echo "$RETRIEVE_RESPONSE" | jq '.results | length' 2>/dev/null || echo "0")

if [[ "$RESULT_COUNT" -eq 0 ]]; then
  echo "Ruby returned no results for your question."
  echo "Raw response: $RETRIEVE_RESPONSE"
  exit 0
fi

# ==============================================================================
# 6. DISPLAY RESULTS
# ==============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Ruby's answer  ($RESULT_COUNT result(s) found)"
echo "════════════════════════════════════════════════════════════"

for i in $(seq 0 $((RESULT_COUNT - 1))); do
  CONTENT=$(echo "$RETRIEVE_RESPONSE"    | jq -r ".results[$i].content")
  SOURCE_URL=$(echo "$RETRIEVE_RESPONSE" | jq -r ".results[$i].sourceUrl // \"(no source)\"")

  echo ""
  echo "  Result $((i + 1)):"
  echo "  ──────────────────────────────────────────────────────"
  echo "$CONTENT" | fold -s -w 72 | sed 's/^/  /'
  echo ""
  echo "  Source: $SOURCE_URL"
done

echo ""
echo "════════════════════════════════════════════════════════════"
