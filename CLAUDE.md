# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of Bash scripts for automating operations against the **Rubrik Security Cloud (RSC) GraphQL API**. Scripts use `curl` + `jq` throughout.

## Credentials

All scripts load credentials from `.env` (never hardcode them):

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

All scripts use the shared `rsc_auth.sh` helper for token caching (Rubrik allows max 10 active tokens per service account):

```bash
source "$SCRIPT_DIR/rsc_auth.sh"
get_rsc_token || exit 1
# RSC_TOKEN is now set in the environment
```

`rsc_auth.sh` decodes the JWT expiry and reuses a cached token from `.rsc_token_cache` as long as it has more than 5 minutes remaining. A new token is only requested when needed.

## GraphQL call patterns

**Standard query (exits on error):**
```bash
gql() {
  local response
  response=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" '{query: $q}')" \
    "https://$RSC_FQDN/api/graphql")
  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "API error:" >&2; echo "$response" | jq '.errors' >&2; exit 1
  fi
  echo "$response"
}
```

**With GraphQL variables (use for mutations with complex inputs to avoid escaping):**
```bash
gql_vars() {
  local response
  response=$(curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')" \
    "https://$RSC_FQDN/api/graphql")
  if echo "$response" | jq -e '.errors' &>/dev/null; then
    echo "API error:" >&2; echo "$response" | jq '.errors' >&2; exit 1
  fi
  echo "$response"
}
```

**Raw (no error exit — for retry logic):**
```bash
gql_vars_raw() {
  curl --silent -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RSC_TOKEN" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')" \
    "https://$RSC_FQDN/api/graphql"
}
```

## Script standards (for new scripts)

- Start with `set -euo pipefail`
- Source `.env` with existence check, then validate vars with `: "${VAR:?message}"`
- Check for `jq` with `command -v jq`
- Use `rsc_auth.sh` for authentication — never inline the token request
- Define `gql()` / `gql_vars()` / `gql_vars_raw()` helpers as needed
- Quote all variable expansions

## Key GraphQL entry points

- **List VMs**: `vSphereVmNewConnection(filter: [{field: IS_RELIC texts: "false"}, {field: IS_REPLICATED texts: "false"}])` → `id name effectiveSlaDomain { id name } powerStatus`
- **VM snapshots**: `vSphereVmNew(fid: "<id>") { snapshotConnection { nodes { id date isOnDemandSnapshot } } }`
- **On-demand backup**: `vsphereBulkOnDemandSnapshot(input: { config: { vms: ["<id>"] slaId: "<id>" } })`
- **Backup status**: `vSphereVMAsyncRequestStatus(id: "<jobId>" clusterUuid: "<clusterId>") { status progress endTime }`
- **VM in-place restore**: `vsphereVmInitiateInPlaceRecovery(input: { id: "<vmId>" config: { requiredRecoveryParameters: { snapshotId: "<snapId>" } } })`
- **VM export to new VM**: `vsphereVmExportSnapshotV2(input: $input)` via GraphQL variables — input `id` = snapshot FID, config includes `hostId`, `datastoreId`, `vmName`, `powerOn`, `keepMacAddresses`, `disableNetwork`, `shouldRecoverTags`, optional `networkDevices: [{networkId}]`
- **List ESXi hosts**: `vSphereHostNewConnection { nodes { id name } }`
- **Host datastores + networks**: `vSphereHostNew(fid: "<hostId>") { datastoreConnection { nodes { id name capacityBytes freeSpaceBytes } } networkConnection { nodes { id name } } }`
- **VM current host**: `vSphereVmNew(fid: "<vmId>") { currentHost { id name } }`
- **File restore**: `vsphereVmRecoverFilesNew(input: $input)` via GraphQL variables — config includes `shouldUseAgent`, `restoreConfig`, optional `guestCredentials`
- **Browse snapshot files**: `browseSnapshotFileConnection(snapshotFid: "<id>" path: "<path>" first: 100)`
- **Restore activity status**: `activitySeriesConnection(filters: { objectFid: "<vmId>" lastActivityType: [Recovery] lastUpdatedTimeGt: "<time>" })`
- **List clusters**: `clusterConnection(filter: {})` — includes `clusterNodeConnection.nodes.interfaceCidrs { interfaceName cidr }`
- **SLA by name**: `slaDomains(filter: {field: NAME text: "…"}) { nodes { id name } }`
- **Create SLA**: `createGlobalSla(input: { name objectTypes snapshotSchedule { daily { basicSchedule { frequency retention retentionUnit } } } })`
- **Assign SLA**: `assignSla(input: { slaDomainAssignType: protectWithSlaId slaOptionalId: "…" objectIds: ["…"] })`
- **Ruby AI chatbots**: `chatbots { nodes { name id } }` → POST `/api/annapurna/<id>/retrieve`

## File restore: Windows vs Linux paths

Rubrik exposes Windows paths as `/C:/foo/bar`. The restore destination must be computed per OS:

- Linux: `/etc/passwd` → restorePath `/restore/etc`
- Windows: `/C:/Files/report.docx` → restorePath `C:/restore/Files`

RBS (Rubrik Backup Service) is tried first without credentials. If RSC returns error `RBK20100125`, fall back to `guestCredentials: { username, password }`.

## Existing scripts

| Script | Purpose |
|---|---|
| `rsc_auth.sh` | Shared token cache helper — source and call `get_rsc_token` |
| `createSLAenv.sh` | Create global SLA — prompts for name |
| `createSLA.sh` | Create global SLA — prompts for name |
| `createSLAandAsign2VM.sh` | Create/find SLA and assign to a VM — prompts for both names |
| `startVMbackup.sh` | Interactive VM selection, triggers on-demand backup |
| `startVMbackupWithStatus.sh` | Same as above, polls and streams backup status |
| `getAllclusters.sh` | List all clusters with capacity metrics — JSON output |
| `getAllclustersWrite2CSV.sh` | Same cluster query — writes `./clusters.csv` |
| `getClusterNetworkInfo.sh` | Cluster node IPs, interfaces, VLAN info (parsed from subinterface names) |
| `askruby.sh` | Query Ruby AI assistant via Annapurna API — requires Annapurna license |
| `restoreVM.sh` | Interactive VM in-place restore — monitors via `activitySeriesConnection` |
| `restoreVMwithExport.sh` | Interactive VM export to new VM — prompts for host, datastore, network, VM name |
| `filerestoreVM.sh` | Interactive file browser + file-level restore — RBS first, guest creds fallback |
