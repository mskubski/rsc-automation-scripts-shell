#!/bin/bash

export RSC_FQDN="rubrik-rcf-86506.my.rubrik.com"
export RSC_CLIENT_ID="client|019be083-fde4-7a48-8fdf-a793cb0c08ec"
export RSC_CLIENT_SECRET="zEhKZ8nPQdT0dqf7F8B5hZrsiJPnlylqFFJMKKNcDGKAC57lMeCeB3-u2aM5WE5O"

RSC_TOKEN=$(curl --silent --location "https://$RSC_FQDN/api/client_token" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$RSC_CLIENT_ID&client_secret=$RSC_CLIENT_SECRET&grant_type=client_credentials" | jq -r '.access_token')

export RSC_TOKEN

# RSC_TOKEN="YOUR_RSC_ACCESS_TOKEN"
query="mutation createSla { createGlobalSla(input: { name: \\\"foo\\\" objectTypes: [VSPHERE_OBJECT_TYPE MSSQL_OBJECT_TYPE] snapshotSchedule: { daily: { basicSchedule: { frequency: 1 retention: 7 retentionUnit: DAYS } } } }) { name id } }"

# Execute the GraphQL query with curl
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "{\"query\": \"$query\"}" \
  https://rubrik-rcf-86506.my.rubrik.com/api/graphql
