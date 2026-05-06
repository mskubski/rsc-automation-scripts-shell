#!/bin/bash
# ==============================================================================
# getClusterNetworkInfo.sh
#
# Description:
#   Queries all Rubrik clusters registered in RSC and displays their network
#   configuration per node, including:
#     - Node hostname and primary IP address
#     - Per-interface name, subnet (CIDR), and VLAN assignment
#     - Network speed and node role
#
# VLAN detection:
#   Rubrik encodes VLAN IDs in the Linux subinterface naming convention.
#   An interface named "bond0.100" means VLAN 100 on bond0.
#   Interfaces without a dot suffix (e.g. "bond0") are untagged (native VLAN).
#
# Requirements:
#   - curl  : for API calls
#   - jq    : for JSON parsing (brew install jq)
#   - .env  : credentials file in the same directory as this script
#
# Usage:
#   bash getClusterNetworkInfo.sh
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. LOAD CONFIGURATION
# ==============================================================================
SCRIPT_DIR="$(dirname "$0")"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "Error: .env file not found at $SCRIPT_DIR/.env" >&2
  echo "       Create it with RSC_FQDN, RSC_CLIENT_ID, RSC_CLIENT_SECRET, RSC_TOKEN_URI set." >&2
  exit 1
fi
source "$SCRIPT_DIR/.env"

: "${RSC_FQDN:?Error: RSC_FQDN not set in .env}"
: "${RSC_CLIENT_ID:?Error: RSC_CLIENT_ID not set in .env}"
: "${RSC_CLIENT_SECRET:?Error: RSC_CLIENT_SECRET not set in .env}"
: "${RSC_TOKEN_URI:?Error: RSC_TOKEN_URI not set in .env}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: brew install jq" >&2
  exit 1
fi

# ==============================================================================
# 2. AUTHENTICATE (uses cached token when still valid)
# ==============================================================================
echo "Connecting to RSC ($RSC_FQDN)..."
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1
echo "-> Authenticated successfully."
echo ""

# ==============================================================================
# 3. QUERY CLUSTER AND NODE NETWORK DATA
#
# Fields used:
#   clusterNodeConnection.nodes.interfaceCidrs
#     - interfaceName : Linux interface name (e.g. bond0, bond0.100, bond1)
#                       VLAN ID is the numeric suffix after the dot, if present.
#     - cidr          : Subnet in CIDR notation (e.g. 10.0.2.0/24)
#   clusterNodeConnection.nodes.ipAddress
#     - The primary management IP assigned to this node
# ==============================================================================
QUERY='query {
  clusterConnection(filter: {}) {
    nodes {
      name
      id
      version
      status
      defaultAddress
      clusterNodeConnection {
        nodes {
          hostname
          brikId
          ipAddress
          status
          networkSpeed
          role
          interfaceCidrs {
            interfaceName
            cidr
          }
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

# Check for API-level errors
if echo "$RESPONSE" | jq -e '.errors' &>/dev/null; then
  echo "Error: API returned errors:" >&2
  echo "$RESPONSE" | jq '.errors' >&2
  exit 1
fi

CLUSTER_COUNT=$(echo "$RESPONSE" | jq '.data.clusterConnection.nodes | length')

if [[ "$CLUSTER_COUNT" -eq 0 ]]; then
  echo "No clusters found in RSC inventory."
  exit 0
fi

echo "Found $CLUSTER_COUNT cluster(s)."
echo ""

# ==============================================================================
# 4. FORMAT AND DISPLAY OUTPUT
# ==============================================================================
for ci in $(seq 0 $((CLUSTER_COUNT - 1))); do
  CLUSTER=$(echo "$RESPONSE" | jq ".data.clusterConnection.nodes[$ci]")

  C_NAME=$(echo "$CLUSTER"    | jq -r '.name')
  C_ID=$(echo "$CLUSTER"      | jq -r '.id')
  C_VERSION=$(echo "$CLUSTER" | jq -r '.version')
  C_STATUS=$(echo "$CLUSTER"  | jq -r '.status')
  C_ADDR=$(echo "$CLUSTER"    | jq -r '.defaultAddress')

  echo "════════════════════════════════════════════════════════════"
  echo "  Cluster  : $C_NAME"
  echo "  ID       : $C_ID"
  echo "  Version  : $C_VERSION"
  echo "  Status   : $C_STATUS"
  echo "  Address  : $C_ADDR"
  echo "════════════════════════════════════════════════════════════"

  NODE_COUNT=$(echo "$CLUSTER" | jq '.clusterNodeConnection.nodes | length')

  if [[ "$NODE_COUNT" -eq 0 ]]; then
    echo "  (no node data available)"
    echo ""
    continue
  fi

  for ni in $(seq 0 $((NODE_COUNT - 1))); do
    NODE=$(echo "$CLUSTER" | jq ".clusterNodeConnection.nodes[$ni]")

    N_HOST=$(echo "$NODE"  | jq -r '.hostname')
    N_BRIK=$(echo "$NODE"  | jq -r '.brikId')
    N_IP=$(echo "$NODE"    | jq -r '.ipAddress')
    N_STATUS=$(echo "$NODE"| jq -r '.status')
    N_SPEED=$(echo "$NODE" | jq -r '.networkSpeed')
    N_ROLE=$(echo "$NODE"  | jq -r '.role')

    echo ""
    echo "  ┌─ Node: $N_HOST (Brik ID: $N_BRIK)"
    echo "  │  Primary IP   : $N_IP"
    echo "  │  Status       : $N_STATUS"
    echo "  │  Network Speed: $N_SPEED"
    [[ "$N_ROLE" != "NONE" && "$N_ROLE" != "null" ]] && \
    echo "  │  Role         : $N_ROLE"

    IFACE_COUNT=$(echo "$NODE" | jq '.interfaceCidrs | length')

    if [[ "$IFACE_COUNT" -eq 0 ]]; then
      echo "  │  Interfaces   : (none reported)"
    else
      echo "  │"
      echo "  │  Interfaces:"
      printf "  │    %-18s %-20s %s\n" "Interface" "Subnet (CIDR)" "VLAN"
      echo "  │    ──────────────────────────────────────────────────"

      for ii in $(seq 0 $((IFACE_COUNT - 1))); do
        IFACE=$(echo "$NODE" | jq ".interfaceCidrs[$ii]")
        I_NAME=$(echo "$IFACE" | jq -r '.interfaceName')
        I_CIDR=$(echo "$IFACE" | jq -r '.cidr')

        # Extract VLAN ID from interface name suffix (e.g. bond0.100 → VLAN 100)
        if [[ "$I_NAME" =~ \.[0-9]+$ ]]; then
          VLAN_ID="${I_NAME##*.}"
          VLAN_LABEL="VLAN $VLAN_ID"
        else
          VLAN_LABEL="untagged (native)"
        fi

        printf "  │    %-18s %-20s %s\n" "$I_NAME" "$I_CIDR" "$VLAN_LABEL"
      done
    fi

    echo "  └──────────────────────────────────────────────────────"
  done

  echo ""
done

echo "Done."
