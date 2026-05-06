# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash scripts for automating operations against the **Rubrik Security Cloud (RSC) GraphQL API**. Scripts use `curl` + `jq` throughout. The `Rubrik-Security-Cloud-API/` subdirectory is a reference library of canonical `.gql` queries and matching `.sh`/`.ps1` wrappers organised by product area.

## Credentials

All new scripts must load credentials from `.env` (never hardcode them):

```bash
source "$(dirname "$0")/.env"
```

Variables provided by `.env`:

| Variable | Purpose |
|---|---|
| `RSC_FQDN` | Hostname of the RSC tenant |
| `RSC_CLIENT_ID` | Service account client ID |
| `RSC_CLIENT_SECRET` | Service account secret |
| `RSC_TOKEN_URI` | OAuth2 token endpoint |
| `RSC_NAME` | Friendly name for this service account |

## Authentication pattern

Every script must obtain a bearer token before calling the API:

```bash
TOKEN_RESPONSE=$(curl --silent --location "$RSC_TOKEN_URI" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$RSC_CLIENT_ID&client_secret=$RSC_CLIENT_SECRET&grant_type=client_credentials")

RSC_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [[ -z "$RSC_TOKEN" || "$RSC_TOKEN" == "null" ]]; then
  echo "Error: Failed to obtain access token." >&2
  exit 1
fi
```

## GraphQL call pattern

All API calls go to `https://$RSC_FQDN/api/graphql` via POST. Use `jq -n` to safely build the JSON payload when variables are embedded in the query:

```bash
JSON_PAYLOAD=$(jq -n --arg q "$QUERY" '{query: $q}')
RESPONSE=$(curl --silent -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RSC_TOKEN" \
  -d "$JSON_PAYLOAD" \
  "https://$RSC_FQDN/api/graphql")
```

For inline string mutations that embed IDs directly, escape inner quotes with `\\\"`.

## Script standards (for new scripts)

- Start with `set -euo pipefail`
- `source .env` with existence check
- Validate required env vars with `: "${VAR:?message}"`
- Check for `jq` with `command -v jq`
- Validate token is non-null before proceeding
- Quote all variable expansions: `echo "$VAR"` not `echo $VAR`
- Print formatted JSON with `echo "$RESPONSE" | jq .`

## Reference library (`Rubrik-Security-Cloud-API/`)

Each `.gql` file is the canonical query/mutation. The paired `.sh` wraps it with `curl`. Look here first before writing new queries:

| Directory | Coverage |
|---|---|
| `Data-Protection/Data-Center/VMware-vSphere/` | VM snapshots, export, live mount, file recovery |
| `Data-Protection/SLA-Domains/` | SLA CRUD |
| `Data-Protection/Snapshots/` | Snapshot assignment, deletion, legal hold |
| `Observability/` | Events, metrics, reports |
| `SaaS-App-Protection/microsoft-m365/` | M365 mailboxes, OneDrive, Teams, SharePoint |
| `Threat-Analytics/` | Anomaly detection, threat hunt (YARA), threat monitoring |
| `System-Settings/` | Users, certificates |
| `Annapurna/` | LangChain/Python AI integration with RSC |

## Key GraphQL entry points

- **List VMs**: `vSphereVmNewConnection` — filter by `IS_RELIC: false`, `IS_REPLICATED: false`; returns `id`, `name`, `effectiveSlaDomain { id name }`
- **On-demand VM backup**: `vsphereBulkOnDemandSnapshot(input: { config: { vms: ["<id>"] slaId: "<id>" } })`
- **List clusters**: `clusterConnection(filter: {})` — returns capacity metrics and node info
- **SLA by name**: `slaDomains(filter: {field: NAME text: "…"})` 
- **SLA by ID**: `slaDomain(id: "…")` — full policy detail including replication and archival specs
- **Assign SLA**: `assignSla(input: { slaDomainAssignType: protectWithSlaId slaOptionalId: "…" objectIds: ["…"] })`

## Existing scripts (status)

| Script | Uses `.env` | Notes |
|---|---|---|
| `createSLAenv.sh` | Yes | Prompts for SLA name; reference implementation |
| `startVMbackup.sh` | Yes | Lists VMs interactively, triggers on-demand backup with object's own SLA |
| `createSLA.sh` | No | Legacy — hardcoded creds |
| `createSLAandAsign2VM.sh` | No | Legacy — hardcoded creds |
| `getAllclusters.sh` | No | Legacy — hardcoded creds |
| `getAllclustersWrite2CSV.sh` | No | Legacy — writes `./clusters.csv` |
| `slaDomainfromRSC.sh` | No | Broken — missing auth block; hardcoded SLA UUID |
| `slaDomainsByNameGet.sh` | No | Legacy — hardcoded search term `"foo"` |
