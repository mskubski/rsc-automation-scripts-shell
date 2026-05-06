#!/bin/bash

# ==============================================================================
# 1. CONFIGURATION / VARIABLES
# ==============================================================================

# Define the name for the new SLA Domain you want to create
NEW_SLA_NAME="Maurice"

# Define the exact name of the VM you want to protect
TARGET_VM_NAME="win2016-fs"

# Rubrik Security Cloud Credentials
export RSC_FQDN="rubrik-rcf-86506.my.rubrik.com"
export RSC_CLIENT_ID="client|019be083-fde4-7a48-8fdf-a793cb0c08ec"
export RSC_CLIENT_SECRET="zEhKZ8nPQdT0dqf7F8B5hZrsiJPnlylqFFJMKKNcDGKAC57lMeCeB3-u2aM5WE5O"

# Check if jq is installed (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it to run this script."
    exit 1
fi

# ==============================================================================
# 2. AUTHENTICATION (Get Bearer Token)
# ==============================================================================
echo "Step 1: Authenticating with RSC..."

# Request the token using Client Credentials Grant
TOKEN_RESPONSE=$(curl --silent --location "https://$RSC_FQDN/api/client_token" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$RSC_CLIENT_ID&client_secret=$RSC_CLIENT_SECRET&grant_type=client_credentials")

# Extract the access token using jq
RSC_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')

# Validate if token was received
if [ "$RSC_TOKEN" == "null" ] || [ -z "$RSC_TOKEN" ]; then
  echo "Error: Failed to retrieve access token. Check credentials."
  echo "Response: $TOKEN_RESPONSE"
  exit 1
fi
echo "-> Authentication successful."

# ==============================================================================
# 3. CREATE OR FIND SLA DOMAIN
# ==============================================================================
echo "Step 2: Ensuring SLA Domain '$NEW_SLA_NAME' exists..."

# First, try to find an existing SLA with the same name
SLA_SEARCH_QUERY="query { slaDomains(filter: {field: NAME text: \"$NEW_SLA_NAME\"}) { nodes { id name } } }"
JSON_PAYLOAD=$(jq -n --arg q "$SLA_SEARCH_QUERY" '{query: $q}')
SLA_SEARCH_RESPONSE=$(curl --silent -X POST \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "https://$RSC_FQDN/api/graphql")

# Extract existing SLA ID if present by exact name match
# Use jq to select nodes where the name equals the requested name exactly
EXISTING_SLA_ID=$(echo "$SLA_SEARCH_RESPONSE" | jq -r --arg name "$NEW_SLA_NAME" '.data.slaDomains.nodes[] | select(.name == $name) | .id' | head -n 1)

if [ -n "$EXISTING_SLA_ID" ] && [ "$EXISTING_SLA_ID" != "null" ]; then
  NEW_SLA_ID=$EXISTING_SLA_ID
  echo "-> Found existing SLA with exact name '$NEW_SLA_NAME'. ID: $NEW_SLA_ID"
else
  echo "-> No existing SLA found. Creating new SLA Domain '$NEW_SLA_NAME'..."

  # Define the Mutation to create the SLA.
  # Config: Daily backup, retention 7 days.
  CREATE_SLA_QUERY="mutation createSla { 
    createGlobalSla(input: { 
      name: \"$NEW_SLA_NAME\" 
      objectTypes: [VSPHERE_OBJECT_TYPE] 
      snapshotSchedule: { 
        daily: { basicSchedule: { frequency: 1 retention: 7 retentionUnit: DAYS } } 
      } 
    }) { 
      id 
      name 
    } 
  }"

  # Build valid JSON payload
  JSON_PAYLOAD=$(jq -n --arg q "$CREATE_SLA_QUERY" '{query: $q}')

  # Execute API Call
  SLA_RESPONSE=$(curl --silent -X POST \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    "https://$RSC_FQDN/api/graphql")

  # Extract the new SLA ID
  NEW_SLA_ID=$(echo $SLA_RESPONSE | jq -r '.data.createGlobalSla.id')

  # Check if creation was successful
  if [ "$NEW_SLA_ID" == "null" ] || [ -z "$NEW_SLA_ID" ]; then
    echo "Error: Failed to create SLA. Response: $SLA_RESPONSE"
    exit 1
  fi
  echo "-> SLA created successfully. ID: $NEW_SLA_ID"
fi

# ==============================================================================
# 4. FIND VM ID (Lookup by Name)
# ==============================================================================
echo "Step 3: Searching for VM '$TARGET_VM_NAME' to get its ID..."

# GraphQL Query to find the VM by name
# Use the supported vSphere VM connection field (vSphereVmNewConnection) and a filter
VM_QUERY="query { vSphereVmNewConnection(filter: [{field: NAME texts: \"$TARGET_VM_NAME\"}]) { nodes { id name } } }"

# Build valid JSON payload
JSON_PAYLOAD=$(jq -n --arg q "$VM_QUERY" '{query: $q}')

# Execute API Call
VM_RESPONSE=$(curl --silent -X POST \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "https://$RSC_FQDN/api/graphql")

# Extract the VM ID (taking the first result)
VM_ID=$(echo $VM_RESPONSE | jq -r '.data.vSphereVmNewConnection.nodes[0].id')

# Check if VM was found
if [ "$VM_ID" == "null" ] || [ -z "$VM_ID" ]; then
  echo "Error: VM '$TARGET_VM_NAME' not found in Rubrik Inventory."
  # Print raw response for debugging so we can see why no nodes were returned
  echo "Response: $VM_RESPONSE"
  exit 1
fi
echo "-> VM found. ID: $VM_ID"

# ==============================================================================
# 5. ASSIGN SLA TO VM
# ==============================================================================
echo "Step 4: Assigning the new SLA to the VM..."

# Mutation to assign the SLA using the IDs we found in Step 3 and 4
ASSIGN_QUERY="mutation assignSla { 
  assignSla(input: { 
    slaDomainAssignType: protectWithSlaId 
    slaOptionalId: \"$NEW_SLA_ID\" 
    objectIds: [\"$VM_ID\"] 
  }) { 
    success 
  } 
}"

# Build valid JSON payload
JSON_PAYLOAD=$(jq -n --arg q "$ASSIGN_QUERY" '{query: $q}')

# Execute API Call
ASSIGN_RESPONSE=$(curl --silent -X POST \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "https://$RSC_FQDN/api/graphql")

# Check result
SUCCESS=$(echo $ASSIGN_RESPONSE | jq -r '.data.assignSla.success')

if [ "$SUCCESS" == "true" ]; then
  echo "SUCCESS! VM '$TARGET_VM_NAME' is now protected by SLA '$NEW_SLA_NAME'."
else
  echo "Error: Assignment failed."
  echo "Response: $ASSIGN_RESPONSE"
  exit 1
fi