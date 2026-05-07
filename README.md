# RSC Automation Scripts

Bash scripts for automating operations against the **Rubrik Security Cloud (RSC) GraphQL API**.
All scripts are written in Bash and require `curl` and `jq`.

---

## Prerequisites

- **curl** — for making HTTP requests to the RSC API
- **jq** — for parsing JSON responses (`brew install jq` on macOS)
- A Rubrik Security Cloud **Service Account** with the required permissions

---

## Credentials — `.env` file

All scripts load credentials from a `.env` file in the same directory.

This file must exist before running any script that sources it.

**.env format:**

```bash
RSC_CLIENT_ID="client|xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
RSC_CLIENT_SECRET="your-client-secret"
RSC_NAME="your-service-account-name"
RSC_TOKEN_URI="https://<tenant>.my.rubrik.com/api/client_token"
RSC_FQDN="<tenant>.my.rubrik.com"
```

| Variable          | Description                                              |
|-------------------|----------------------------------------------------------|
| `RSC_CLIENT_ID`   | Service account client ID (starts with `client|`)       |
| `RSC_CLIENT_SECRET` | Service account secret                                 |
| `RSC_NAME`        | Friendly name for this service account (informational)  |
| `RSC_TOKEN_URI`   | Full URL of the OAuth2 token endpoint                   |
| `RSC_FQDN`        | Hostname of the RSC tenant (used for all API calls)     |

> The `.env` file contains sensitive credentials. Do not commit it to version control.
> Scripts source it with: `source "$(dirname "$0")/.env"`

---

## Token caching — `rsc_auth.sh`

Rubrik limits each service account to **10 active tokens** at a time. To avoid exhausting this limit when running multiple scripts in sequence, all current scripts share a token cache via `rsc_auth.sh`.

**How it works:**

1. On first run, a token is requested from RSC and written to `.rsc_token_cache` with permissions `600` (owner-only).
2. On subsequent runs, the cached token's expiry is decoded from the JWT — no API call is made.
3. The cached token is reused as long as it has more than **5 minutes** remaining (configurable via `TOKEN_BUFFER_SECONDS`).
4. When the token is near expiry, a new one is requested and the cache is updated.

```
Authenticating with RSC...
-> Using cached token (expires in 43199s).   ← reused, no new token consumed
```

```
Authenticating with RSC...
-> New token obtained (expires in 43200s, cached to .rsc_token_cache).   ← fresh token
```

**Files:**

| File | Purpose |
|---|---|
| `rsc_auth.sh` | Shared helper — source this, then call `get_rsc_token` |
| `.rsc_token_cache` | Cached JWT token (auto-created, do not edit manually) |

> Add `.rsc_token_cache` to `.gitignore` alongside `.env`.

To override the buffer window (e.g. 10 minutes):
```bash
TOKEN_BUFFER_SECONDS=600 bash startVMbackup.sh
```

---

## Scripts

### `createSLAenv.sh` *(current)*

Creates a new global SLA domain for vSphere and MSSQL object types with a daily backup schedule (1x per day, 7-day retention).

**Uses:** `.env` file

**Usage:**
```bash
bash createSLAenv.sh
```

The script interactively prompts for the SLA name:
```
Enter SLA name: MyNewSLA
```

**Output:** JSON response with the created SLA `name` and `id`.

---

### `startVMbackup.sh` *(current)*

Lists all non-relic, non-replicated vSphere VMs with their assigned SLA, lets the user select one by number, and triggers an immediate on-demand backup using the object's own effective SLA.

**Uses:** `.env` file

**Usage:**
```bash
bash startVMbackup.sh
```

Example interaction:
```
Available VMs:
--------------------------------------------------------------
  No.  VM Name                                  Assigned SLA
--------------------------------------------------------------
  1    my-vm-01                                 Platinum
  2    my-vm-02                                 Gold
--------------------------------------------------------------

Enter the number of the VM to back up: 1
```

**Output:** Confirmation with the backup Job ID on success.

---

### `startVMbackupWithStatus.sh` *(current)*

Same as `startVMbackup.sh` but additionally polls the job status every 10 seconds and prints live progress until the backup completes. Status messages match what is shown in the RSC GUI.

**Uses:** `.env` file

**Usage:**
```bash
bash startVMbackupWithStatus.sh
```

**Status messages during polling:**

| API Status  | Displayed message              |
|-------------|-------------------------------|
| `QUEUED`    | `Queued`                      |
| `RUNNING`   | `Taking snapshot... X%`       |
| `SUCCEEDED` | `Snapshot complete`           |
| `FAILED`    | `Failed: <error message>`     |
| `CANCELED`  | `Canceled`                    |

The script exits automatically when the backup finishes (exit code `0` on success, `1` on failure or cancellation). A summary with start time, end time, and Job ID is printed on completion.

---

### `getClusterNetworkInfo.sh` *(current)*

Queries all Rubrik clusters registered in RSC and displays their network configuration per node, including interface names, subnets (CIDR), and VLAN assignments.

**Uses:** `.env` file

**Usage:**
```bash
bash getClusterNetworkInfo.sh
```

**Output:** Formatted per-cluster, per-node table showing:
- Cluster name, ID, version, status, and default address
- Per node: hostname, Brik ID, primary IP, status, network speed
- Per interface: interface name, subnet (CIDR), and VLAN status

**VLAN detection:** Rubrik uses Linux subinterface naming to encode VLANs. An interface named `bond0.100` is automatically identified as VLAN 100. Interfaces without a numeric suffix (e.g. `bond0`) are shown as `untagged (native)`.

```
  │  Interfaces:
  │    Interface          Subnet (CIDR)        VLAN
  │    ──────────────────────────────────────────────────
  │    bond0              10.0.2.0/24          untagged (native)
  │    bond0.100          10.0.100.0/24        VLAN 100
```

---

### `askruby.sh` *(current — requires Annapurna license)*

Sends a natural-language question to **Ruby**, Rubrik's AI assistant, via the RSC Annapurna API, and displays the answer with source references.

**Uses:** `.env` file

**Requires:** The Annapurna / Ruby AI feature must be licensed and enabled on the RSC tenant. If not, the script exits with a clear error message.

**Usage:**
```bash
bash askruby.sh
```

**How it works:**

1. Queries `chatbots` via GraphQL to list available Ruby chatbots (retrievers).
2. Auto-selects the chatbot if only one exists; shows a numbered menu if multiple are configured.
3. Prompts for a natural-language question.
4. POSTs the question to the Annapurna REST endpoint:
   ```
   POST https://<tenant>/api/annapurna/<chatbot-id>/retrieve
   ```
5. Displays each result with its content and source URL.

**Example interaction:**
```
Ask Ruby: What is the retention policy for the Platinum SLA?

════════════════════════════════════════════════════════════
  Ruby's answer  (2 result(s) found)
════════════════════════════════════════════════════════════

  Result 1:
  ──────────────────────────────────────────────────────
  The Platinum SLA retains daily snapshots for 30 days...

  Source: https://docs.rubrik.com/...
```

> If the Annapurna feature is not licensed on the RSC tenant, the script exits with:
> `Error: Could not access Ruby chatbots. Reason: Account does not have the appropriate features enabled.`

---

### `restoreVM.sh` *(current)*

Interactively restores a VMware vSphere VM from a selected snapshot using in-place recovery (overwrites the existing VM with the snapshot state).

**Uses:** `.env` file

**Usage:**
```bash
bash restoreVM.sh
```

**Flow:**

1. Lists all non-relic VMs with SLA and power state — user selects by number.
2. Fetches all snapshots for the selected VM, sorted newest first (max 30 shown), with date and type — user selects by number.
3. Displays a confirmation summary and requires the user to type `YES` before proceeding — any other input cancels cleanly.
4. Initiates in-place recovery via `vsphereVmInitiateInPlaceRecovery`.
5. Polls every 15 seconds and streams live status until the restore finishes.

**Status monitoring:**

The monitoring uses `activitySeriesConnection` (filtered by VM object ID and activity type `Recovery`) as the primary status source, since the restore job ID format (`INPLACE_EXPORT_...`) is not supported by `vSphereVMAsyncRequestStatus`. The async status API is queried as a secondary source to supplement progress % and timestamps.

| Activity status       | Displayed message          |
|-----------------------|---------------------------|
| `Queued`              | `Queued`                  |
| `Running`             | `Restoring... X%`         |
| `Success / TaskSuccess` | `Restore complete`      |
| `Failure / TaskFailure` | `Failed`                |
| `Canceled`            | `Canceled`                |

The script exits with code `0` on success (prints start/end time and Job ID) or code `1` on failure or cancellation.

> **Warning:** In-place recovery overwrites the running VM. The confirmation step requires typing `YES` in full — this cannot be undone.

---

### `restoreVMwithExport.sh` *(current)*

Interactively exports a VMware vSphere VM snapshot to a new VM (non-destructive). Unlike in-place recovery, the original VM is not modified — a new VM is created from the selected snapshot.

**Uses:** `.env` file

**Usage:**
```bash
bash restoreVMwithExport.sh
```

**Flow:**

1. Lists all non-relic VMs with SLA and power state — user selects by number.
2. Fetches all snapshots for the selected VM, sorted newest first (max 30 shown) — user selects by number.
3. Resolves the VM's ESXi host automatically via `physicalPath`, then lists all datastores on that host — user selects by number (default: 1).
4. Displays available networks on the host for reference — original network assignments are kept on the exported VM.
5. Prompts for new VM name (default: original VM name) and power-on preference (default: yes).
6. Displays a confirmation summary and requires the user to type `YES` before proceeding.
7. Initiates export via `vsphereVmExportSnapshotV2`.
8. Polls every 15 seconds and streams live status until the export completes.

**Export parameters:**

| Parameter | Prompt | Default |
|-----------|--------|---------|
| Datastore | Select from numbered list | First in list |
| Network | Informational display only | Original assignments kept |
| VM name | Free text | Original VM name |
| Power on | `[Y/n]` | Yes |

> **Network reassignment:** The RSC API requires vSphere-internal MOID and NIC device keys for per-NIC network remapping, which are not exposed via the GraphQL API. Networks are therefore always kept from the snapshot. Reassign networks in vSphere after export if needed.

**Status monitoring:**

Uses `activitySeriesConnection` (filtered by VM object ID and activity type `Recovery`) as the primary status source, supplemented by `vSphereVMAsyncRequestStatus` for progress % and timestamps.

| Activity status | Displayed message |
|----------------|-------------------|
| `Queued` | `Queued` |
| `Running` | `Exporting... X%` |
| `Success / TaskSuccess` | `Export complete` |
| `Failure / TaskFailure` | `Failed` |
| `Canceled` | `Canceled` |

The script exits with code `0` on success or code `1` on failure or cancellation. A full summary is printed on completion:

```
Export completed successfully.
  Source VM   : my-vm-01
  Snapshot    : 2026-05-01T03:57:34.000Z
  Cluster     : Rubrik-Demo1
  New VM name : my-vm-01-export
  Datastore   : DS-SSD-01
  Network     : (keep original)
  Power on    : true
  Duration    : 4m 32s
  Start time  : 2026-05-01T03:58:00.000Z
  End time    : 2026-05-01T04:02:32.000Z
  Job ID      : PARALLEL_EXPORT_VMWARE_SNAPSHOT_...
```

---

### `filerestoreVM.sh` *(current)*

Interactively browses a VMware vSphere VM snapshot file system and restores selected files and/or directories to a `/restore` folder on the source VM, preserving the original path structure. Supports both Windows and Linux VMs.

**Uses:** `.env` file

**Usage:**
```bash
bash filerestoreVM.sh
```

**Flow:**

1. Lists all non-relic VMs with SLA and power state — user selects by number.
2. Fetches all snapshots for the selected VM, sorted newest first (max 30 shown) — user selects by number.
3. Opens an interactive file browser to navigate the snapshot file system and select items for restore.
4. Displays a confirmation summary and requires the user to type `YES` before proceeding.
5. Attempts restore via **RBS (Rubrik Backup Service)** — no credentials needed if RBS is installed on the VM. If RSC returns error `RBK20100125` (guest OS credentials required), RBS is not present and the script prompts for a guest OS username and password, then retries automatically.
6. Polls every 15 seconds and streams live status until the restore finishes.

**File browser commands:**

| Command        | Action                                                    |
|----------------|-----------------------------------------------------------|
| `<number>`     | Enter a directory, or toggle selection on a file          |
| `s <number>`   | Select / deselect any item by number (file or directory)  |
| `s .`          | Select / deselect the current directory itself            |
| `..`           | Go up one level                                           |
| `ls`           | List all currently selected items and their restore paths |
| `done`         | Proceed to the restore confirmation step                  |
| `q`            | Quit without restoring                                    |

Selected items are marked with `*` in the directory listing.

**Restore path mapping:**

The script auto-detects Windows vs Linux paths and maps to the correct restore location.

| VM type | Original path                    | Restored to                             |
|---------|----------------------------------|-----------------------------------------|
| Windows | `/C:/Files/IT Department/f.docx` | `C:/restore/Files/IT Department/f.docx` |
| Windows | `/C:/report.txt`                 | `C:/restore/report.txt`                 |
| Linux   | `/etc/passwd`                    | `/restore/etc/passwd`                   |
| Linux   | `/home/user/`                    | `/restore/home/user/`                   |

**Status monitoring:**

Monitoring uses `activitySeriesConnection` filtered by `lastActivityType: [Recovery, LocalRecovery]`, the same approach as `restoreVM.sh`.

| Activity status         | Displayed message               |
|-------------------------|---------------------------------|
| `Queued / unknown`      | `Restoring files... 0%`         |
| `Running`               | `Restoring files... X%`         |
| `Success / TaskSuccess` | `File restore complete`         |
| `Failure / TaskFailure` | `Failed`                        |
| `Canceled`              | `Canceled`                      |

> **Progress stays at 0% throughout — this is normal.** Rubrik's activity API tracks job lifecycle events, not per-file copy throughput. The job completes atomically and the status flips directly from Running to Success without intermediate progress values.

On success the script prints a full summary:

```
File restore completed successfully.
  VM       : zaffre-fs
  Cluster  : Rubrik-Demo1
  Snapshot : 2026-05-01T03:57:34.000Z
  Duration : 2m 21s
  Job ID   : RESTORE_FILE_...

  Restored items (source  ->  destination on zaffre-fs):
    /C:/Files/IT Department
      ->  C:/restore/Files/IT Department
```

The script exits with code `0` on success or code `1` on failure or cancellation.

> **Note:** Multiple files and entire directories can be selected in a single restore operation. RBS is attempted first with no credential prompt. Guest credentials are only requested if RBS is not installed — the password prompt is silent (no echo) and credentials are never logged.

---

### `getAllclusters.sh` *(current)*

Queries all Rubrik clusters registered in RSC and prints detailed JSON output including capacity metrics, node details, geo-location, and status information.

**Uses:** `.env` file

**Usage:**
```bash
bash getAllclusters.sh
```

**Output:** Formatted JSON with full cluster inventory including capacity metrics (`totalCapacity`, `availableCapacity`, `usedCapacity`, `averageDailyGrowth`), node details, and geo-location.

---

### `getAllclustersWrite2CSV.sh` *(current)*

Same cluster query as `getAllclusters.sh` but writes results to `clusters.csv` in the current working directory instead of printing to the terminal. Useful for reporting or importing into spreadsheet tools.

**Uses:** `.env` file

**Usage:**
```bash
bash getAllclustersWrite2CSV.sh
```

**Output:** `./clusters.csv` with one row per cluster. Existing file is overwritten without warning. A count of written rows is printed on completion.

**CSV columns:** `name, id, type, version, defaultAddress, systemStatus, status, subStatus, pauseStatus, encryptionEnabled, eosDate, eosStatus, registrationTime, registeredMode, estimatedRunway, geoAddress, geoLatitude, geoLongitude`

---

### `createSLA.sh` *(current)*

Creates a new global SLA domain for vSphere and MSSQL object types with a daily backup schedule (1x per day, 7-day retention). Prompts interactively for the SLA name.

**Uses:** `.env` file

**Usage:**
```bash
bash createSLA.sh
```

The script prompts for the SLA name:
```
Enter SLA name: MyNewSLA
```

**Output:** JSON response with the created SLA `name` and `id`.

---

### `createSLAandAsign2VM.sh` *(current)*

Creates a new SLA domain (or reuses one with the same name if it already exists) and assigns it to a specific VM. Both names are entered interactively.

**Uses:** `.env` file

**Usage:**
```bash
bash createSLAandAsign2VM.sh
```

Example interaction:
```
SLA name: GoldSLA
VM name:  win2016-fs
```

**Flow:**

1. Searches RSC for an existing SLA with the exact name provided.
2. If not found: creates a new global SLA (vSphere, daily schedule, 7-day retention).
3. Finds the VM by name in the vSphere inventory.
4. Assigns the SLA to the VM.

**Output:** Confirmation message on success or a detailed error if any step fails.

