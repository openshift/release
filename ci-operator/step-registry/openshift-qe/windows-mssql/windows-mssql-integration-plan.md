# Implementation Plan: Add Windows MSSQL Workload to OpenShift CI

## Context

**Goal:** Integrate the `windows-mssql` workload from [kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539) into the OpenShift release repository CI pipeline, following the pattern established by the windows-bootstorm workload in [PR #84309](https://github.com/openshift/release/pull/84309).

**Why:** Enable automated SQL Server TPC-C performance benchmarking on Windows VMs in OpenShift CI. The workload provisions a Windows VM running SQL Server, builds a TPC-C schema, and drives it with HammerDB to measure transactions per minute.

**What the workload does:**
- Provisions Windows VMs with SQL Server and a TPC-C database
- Runs a HammerDB TPC-C benchmark with configurable warehouses, transactions, and user counts
- Collects TPM (Transactions Per Minute) metrics
- Supports LVMS (per-node DataVolumes) and ODF (VolumeSnapshot) storage backends
- Uses virtctl ssh/scp for benchmark script transfer and execution
- Indexes results to Elasticsearch for Orion regression detection

**Target integration:** An on-demand (`always_run: false`) validation job on the `metal-perfscale-cpt` cluster profile, run manually before the workload is added to a scheduled job.

**Storage strategy:** LVMS with per-node DataVolumes, using the existing `openshift-qe-installer-bm-day2-lvms` setup. ODF support is a follow-up.

**Metrics:** Primary metric is TPM (Transactions Per Minute). NOPM (New Orders Per Minute) is not required.

---

## Prerequisites

**CRITICAL DEPENDENCIES:** This implementation depends on two related PRs:

1. **[kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539)** — Windows MSSQL workload implementation
   - Must be **merged and released** before the job can run
   - Provides the `windows-mssql` workload and its flags
   - The CI image bundles kube-burner-ocp; until the release containing PR #539 is picked up, the job fails with `unknown command 'windows-mssql' for 'kube-burner-ocp'`

2. **[Orion PR #487](https://github.com/cloud-bulldozer/orion/pull/487)** — Orion configuration for windows-mssql
   - Must be merged to enable regression detection
   - Provides `examples/metal-perfscale-cpt-windows-mssql.yaml`
   - Defines metrics, thresholds, and change point detection

**Before triggering the job:**
1. ✅ kube-burner-ocp PR #539 merged and released
2. ✅ CI image rebuilt with the release containing the workload
3. ✅ Orion PR #487 merged with the CPT configuration
4. ✅ Windows image reachable from the test cluster

---

## Files

### 1. Main Workload Step Registry

**Directory:** `ci-operator/step-registry/openshift-qe/windows-mssql/`

#### `openshift-qe-windows-mssql-ref.yaml`
Step definition:

- **Image:** `ocp-qe-perfscale-ci:latest`
- **Timeout:** `5h`
- **Credentials:**
  - ES credentials: `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds` → `/secret`
  - Windows image URL: `perfci/benchmark-runner/windows_url` → `/secret-perfci`
- **Resources:** 100m CPU / 100Mi memory

**Environment variables:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_VERSION` | `default` | e2e-benchmarking tag (default resolves to latest tag) |
| `KUBE_BURNER_VERSION` | `default` | kube-burner-ocp version override |
| `GC` | `true` | Clean up workload resources after run |
| `ENABLE_LOCAL_INDEX` | `false` | Enable local indexing for artifact collection |
| `MSSQL_EXTRA_FLAGS` | `""` | Additional flags passed to the workload |
| `STORAGE_CLASS` | `lvms-nvme` | StorageClass for DataVolumes |
| `ACCESS_MODE` | `RWO` | PVC access mode (RWO for LVMS, RWX for ODF) |
| `EVICTION_STRATEGY` | `None` | VM eviction strategy (None for LVMS, LiveMigrate for ODF) |
| `PER_NODE_DV` | `true` | One source DataVolume per worker node (required for LVMS) |
| `USE_SNAPSHOT` | `false` | Provision data disk from a VolumeSnapshot (ODF) |
| `TOTAL_VMS` | `1` | Number of SQL Server VMs |
| `VM_CPU` | `32` | vCPUs for the VM |
| `VM_CPU_REQUEST` | `32` | CPU request for the VM |
| `VM_MEMORY` | `32Gi` | Memory for the VM |
| `VM_MEMORY_REQUEST` | `32Gi` | Memory request for the VM |
| `IO_THREAD_COUNT` | `8` | Disk I/O threads |
| `NODE_DISTRIBUTION` | `sequential` | VM placement across nodes (`sequential` or `spread`) |
| `ROOT_DISK_SIZE` | `76Gi` | Windows root disk |
| `DATA_DISK_SIZE` | `76Gi` | SQL Server data disk |
| `CDI_SOURCE_TYPE` | `http` | CDI source type for the Windows image |
| `DB_WAREHOUSES` | `96` | TPC-C warehouses (database size) |
| `DB_TRANSACTIONS` | `100000` | Transactions to run |
| `DB_ITERATIONS` | `1` | Benchmark iterations |
| `DB_RAMPUP` | `1m` | Ramp-up time before the benchmark |
| `DB_RUNTIME` | `1m` | Benchmark runtime |
| `DB_USERS` | `1,2,4,8,16,32` | Comma-separated HammerDB user counts to test |
| `NAMESPACE` | `windows-mssql` | Namespace for workload resources |
| `SOURCE_DV_NAME` | `windows-mssql-source-dv` | Name of the source DataVolume |
| `CLEAR_NODE_CACHES` | `true` | Clear node caches before the benchmark |
| `BULK_SLEEP` | `30s` | Sleep between bulk operations |
| `SSH_CONCURRENCY_LIMIT` | `20` | Max concurrent SSH connections to VMs |
| `WINDOWS_IMAGE_URL` | `http://10.26.8.107:8083/windows_server_2k25.qcow2` | Explicit override; Vault value used when unset |
| `ES_SECRETS_PATH` | `""` | Override ES secrets path (defaults to `/secret`) |

**Pattern reference:** `openshift-qe-virt-density-ref.yaml`.

#### `openshift-qe-windows-mssql-commands.sh`
Execution flow:

1. **Setup** — Load proxy config if present, read ES credentials from `/secret`, resolve `WINDOWS_IMAGE_URL` from the Vault mount at `/secret-perfci/windows_url` when not set explicitly, clone `cloud-bulldozer/e2e-benchmarking` at `E2E_VERSION`, and enter `workloads/kube-burner-ocp-wrapper`.

2. **Cluster stabilization** — Poll up to 900s at 20s intervals until all nodes are Ready and the `worker` MCP is neither Updating nor Degraded. Fail the step on timeout.

3. **Virtctl installation** — Resolve the download URL from `consoleclidownload/virtctl-clidownloads-kubevirt-hyperconverged`, download, verify the gzip, extract to `/tmp/bin`, and add to `PATH`.

4. **Workload execution** — Build `EXTRA_FLAGS` and call `./run.sh`:

   ```bash
   export WORKLOAD=windows-mssql

   EXTRA_FLAGS="${MSSQL_EXTRA_FLAGS} --metrics-profile metrics.yml"
   EXTRA_FLAGS+=" --windows-image-url=${WINDOWS_IMAGE_URL}"
   EXTRA_FLAGS+=" --total-vms=${TOTAL_VMS}"
   EXTRA_FLAGS+=" --vm-cpu=${VM_CPU}"
   EXTRA_FLAGS+=" --vm-cpu-request=${VM_CPU_REQUEST}"
   EXTRA_FLAGS+=" --vm-memory=${VM_MEMORY}"
   EXTRA_FLAGS+=" --vm-memory-request=${VM_MEMORY_REQUEST}"
   EXTRA_FLAGS+=" --io-thread-count=${IO_THREAD_COUNT}"
   EXTRA_FLAGS+=" --node-distribution=${NODE_DISTRIBUTION}"
   EXTRA_FLAGS+=" --eviction-strategy=${EVICTION_STRATEGY}"
   EXTRA_FLAGS+=" --storage-class=${STORAGE_CLASS}"
   EXTRA_FLAGS+=" --access-mode=${ACCESS_MODE}"
   EXTRA_FLAGS+=" --root-disk-size=${ROOT_DISK_SIZE}"
   EXTRA_FLAGS+=" --data-disk-size=${DATA_DISK_SIZE}"
   EXTRA_FLAGS+=" --use-snapshot=${USE_SNAPSHOT}"
   EXTRA_FLAGS+=" --per-node-dv=${PER_NODE_DV}"
   EXTRA_FLAGS+=" --cdi-source-type=${CDI_SOURCE_TYPE}"
   EXTRA_FLAGS+=" --db-warehouses=${DB_WAREHOUSES}"
   EXTRA_FLAGS+=" --db-transactions=${DB_TRANSACTIONS}"
   EXTRA_FLAGS+=" --db-iterations=${DB_ITERATIONS}"
   EXTRA_FLAGS+=" --db-rampup=${DB_RAMPUP}"
   EXTRA_FLAGS+=" --db-runtime=${DB_RUNTIME}"
   EXTRA_FLAGS+=" --db-users=${DB_USERS}"
   EXTRA_FLAGS+=" --namespace=${NAMESPACE}"
   EXTRA_FLAGS+=" --source-dv-name=${SOURCE_DV_NAME}"
   EXTRA_FLAGS+=" --clear-node-caches=${CLEAR_NODE_CACHES}"
   EXTRA_FLAGS+=" --bulk-sleep=${BULK_SLEEP}"
   EXTRA_FLAGS+=" --ssh-concurrency-limit=${SSH_CONCURRENCY_LIMIT}"

   if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
       EXTRA_FLAGS+=" --local-indexing=true"
   fi
   EXTRA_FLAGS+=" --es-server=https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
   EXTRA_FLAGS+=" --es-index=ripsaw-kube-burner"
   ```

5. **Artifact collection** — Copy the `collected-metric*` directory to `${ARTIFACT_DIR}/` when local indexing is enabled.

#### `openshift-qe-windows-mssql-ref.metadata.json`
Owner metadata (`perfscale-ocp-approvers` / `perfscale-ocp-reviewers`).

#### `OWNERS`
Symlink to the parent `openshift-qe/OWNERS`.

---

### 2. Orion Regression Detection Wrapper

**Directory:** `ci-operator/step-registry/openshift-qe/orion/windows-mssql/`

#### `openshift-qe-orion-windows-mssql-ref.yaml`
- **Image:** `ocp-qe-perfscale-ci:latest`
- **Timeout:** `6h` (workload 5h + 1h buffer)
- **Commands:** `openshift-qe-orion-windows-mssql-commands.sh` (symlink to the shared Orion script)
- **Credentials:**
  - `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds` → `/secret/qe`
  - `ocp-perfscale-cpt/ocp-perfscale-es-creds` → `/secret/internal`

**Key variables:**
- `ORION_CONFIG: "examples/metal-perfscale-cpt-windows-mssql.yaml"`
- `ES_TYPE: "qe"`
- `ES_BENCHMARK_INDEX: "ripsaw-kube-burner-*"`
- `ES_METADATA_INDEX: "perf_scale_ci-*"`
- `LOOKBACK: "15"` (days)
- `RUN_ORION: "false"` (overridden per job; the validation job sets `deferred`)
- `DISPLAY: "ocpVirtVersion"`
- `CHANGE_POINT_REPOS: "kube-burner/kube-burner,kube-burner/kube-burner-ocp,cloud-bulldozer/e2e-benchmarking,openshift/release"`

With `RUN_ORION: deferred`, Orion failures are reported by the report step rather than failing the workload run — useful while results are still being seeded.

#### `openshift-qe-orion-windows-mssql-commands.sh`
Symlink to `../openshift-qe-orion-commands.sh`, shared by all Orion wrappers.

#### `openshift-qe-orion-windows-mssql-ref.metadata.json` and `OWNERS`
Owner metadata and a symlink to `openshift-qe/OWNERS`.

---

### 3. CI Job Configuration

**File:** `ci-operator/config/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main__metal-5.0-nightly-x86.yaml`

```yaml
- always_run: false
  as: windows-mssql-validation
  capabilities:
  - intranet
  restrict_network_access: false
  steps:
    cluster_profile: metal-perfscale-cpt
    env:
      CNV_VERSION: "5.0"
      ENABLE_LOCAL_INDEX: "true"
      RUN_ORION: deferred
      VERSION: "5.0"
    test:
    - ref: openshift-qe-installer-bm-day2-label
    - ref: openshift-qe-installer-bm-day2-lvms
    - ref: openshift-qe-installer-bm-day2-cnv
    - ref: openshift-qe-windows-mssql
    - ref: openshift-qe-orion-windows-mssql
    - ref: openshift-qe-orion-report
    workflow: openshift-qe-installer-bm-deploy
```

`make update` regenerates `ci-operator/jobs/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main-presubmits.yaml`, producing the job `pull-ci-openshift-eng-ocp-perfscale-main-metal-5.0-nightly-x86-windows-mssql-validation`.

**Future integration:** once validated, add `openshift-qe-windows-mssql` and `openshift-qe-orion-windows-mssql` to the `daily-virt-6nodes` job's test list.

---

## Reused Existing Components

1. **`openshift-qe-installer-bm-day2-label`** — worker labeling
2. **`openshift-qe-installer-bm-day2-lvms`** — LVMS storage setup
3. **`openshift-qe-installer-bm-day2-cnv`** — CNV / OpenShift Virtualization
4. **`openshift-qe-orion-commands.sh`** — shared Orion execution script
5. **`openshift-qe-orion-report`** — Orion report aggregation
6. **`openshift-qe-installer-bm-deploy`** — bare-metal install workflow

**Credentials:**
- `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds` — Elasticsearch credentials
- `perfci/benchmark-runner/windows_url` — Windows image URL

---

## Implementation Approach

### Storage Backend Configuration

**Phase 1: LVMS (this PR)**
- `--per-node-dv=true`, `STORAGE_CLASS=lvms-nvme`, `ACCESS_MODE=RWO`, `EVICTION_STRATEGY=None`
- DataVolumes are per-node, so VMs cannot live-migrate

**Phase 2: ODF (future PR)**
- Separate job variant, override:
  - `STORAGE_CLASS: "ocs-storagecluster-ceph-rbd-virtualization"`
  - `ACCESS_MODE: "RWX"`
  - `EVICTION_STRATEGY: "LiveMigrate"`
  - `PER_NODE_DV: "false"`
  - `USE_SNAPSHOT: "true"`
- Use `openshift-qe-installer-bm-day2-odf` instead of the LVMS step

### Default Configuration Rationale

- **32 vCPU / 32Gi** — SQL Server benefits from high CPU for parallel query processing.
- **1 VM** — intensive single-VM benchmark, not a density test.
- **96 warehouses** — moderate TPC-C database (~10GB) that builds in reasonable time.
- **User counts `1,2,4,8,16,32`, 1 iteration, 1m ramp-up / 1m runtime** — a short smoke-scale sweep across all six user counts used to validate the pipeline; scale up via `DB_USERS` / `DB_ITERATIONS` once results are flowing.

### Timing

- Workload step timeout: 5h. Orion wrapper timeout: 6h.
- Most wall-clock time goes to VM provisioning and the SQL Server / TPC-C build; the benchmark itself is short at the defaults above.

### Metrics

- Profile: `metrics.yml` only.
- ES index: `ripsaw-kube-burner`.
- Local indexing (`--local-indexing=true`) is enabled in the job, so `collected-metric*` is also uploaded to `${ARTIFACT_DIR}`.

---

## Verification Steps

### 1. Configuration Validation
```bash
make update
make validate-step-registry
make checkconfig
```

### 2. Manually Triggering the Job

The job is `always_run: false`, so it must be triggered explicitly.

**Prow command** (on any PR in `openshift-eng/ocp-perfscale`, or via rehearsals on this PR):
```
/test metal-5.0-nightly-x86-windows-mssql-validation
```

**Gangway UI:** https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/ — search for `metal-5.0-nightly-x86-windows-mssql-validation`.

**What happens when triggered:**

1. Cluster allocated from the `metal-perfscale-cpt` pool
2. `openshift-qe-installer-bm-deploy` installs OpenShift
3. Day2 steps install LVMS and CNV
4. `openshift-qe-windows-mssql` runs the benchmark
5. `openshift-qe-orion-windows-mssql` analyzes results (`RUN_ORION=deferred`)
6. `openshift-qe-orion-report` publishes the report

### 3. Integration Checklist
- [ ] Cluster stabilizes before the workload starts
- [ ] VM provisions with LVMS storage (root + data disks)
- [ ] Windows boots and SQL Server is reachable over virtctl ssh
- [ ] TPC-C schema builds with 96 warehouses
- [ ] HammerDB runs each user count (`1,2,4,8,16,32`) and reports TPM per count
- [ ] Results indexed to `ripsaw-kube-burner`
- [ ] `collected-metric*` artifacts uploaded
- [ ] Orion runs against the new documents
- [ ] Job completes within the 5h step / 6h Orion timeouts

### 4. Metrics Validation
```bash
curl -X GET "https://$ES_HOST/ripsaw-kube-burner-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match": {"workload": "windows-mssql"}}}'
```

Expected: `tpm` and supporting workload metadata for the run.

---

## Dependencies and Blockers

1. **[kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539)** — must be merged and released; the flag set above is taken from that implementation.
2. **[Orion PR #487](https://github.com/cloud-bulldozer/orion/pull/487)** — must be merged for `examples/metal-perfscale-cpt-windows-mssql.yaml` to exist.

**Infrastructure:** bare-metal cluster from `metal-perfscale-cpt` with LVMS and CNV installed by day2 steps, Windows image reachable over HTTP, Elasticsearch reachable.

---

## Cost Analysis

### Claude API Token Cost (Planning + Implementation)

- Estimate: ~$1.10–$1.50
- **Actual: $7.58**

Drivers: parallel exploration agents, a design agent, an extended planning session with many clarifications, and long-running `make update` / `make checkconfig`.

### Infrastructure Cost (Per Job Execution)

- **Direct financial cost:** $0 — bare-metal clusters are pre-allocated internal Red Hat infrastructure; OpenShift, Windows, and SQL Server licenses are already covered.
- **Opportunity cost:** a `metal-perfscale-cpt` cluster is occupied for the duration of the run, which is unavailable to other jobs meanwhile.
- **Frequency:** on-demand only initially.

---

## Future Enhancements

- **ODF backend** — separate job variant with `USE_SNAPSHOT` / RWX / LiveMigrate.
- **Larger runs** — raise `DB_USERS`, `DB_ITERATIONS`, or `DB_WAREHOUSES` for production-scale numbers.
- **Multiple VMs** — raise `TOTAL_VMS` for a combined throughput measurement.
- **Scheduled execution** — fold the steps into `daily-virt-6nodes` once validated.
- **Dashboards** — Grafana / TestGrid views for TPM trends.

---

## Summary

**Creates 9 files:**
1. `ci-operator/step-registry/openshift-qe/windows-mssql/windows-mssql-integration-plan.md`
2. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-ref.yaml`
3. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-commands.sh`
4. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-ref.metadata.json`
5. `ci-operator/step-registry/openshift-qe/windows-mssql/OWNERS` (symlink)
6. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-ref.yaml`
7. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-commands.sh` (symlink)
8. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-ref.metadata.json`
9. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/OWNERS` (symlink)

**Modifies 2 files:**
1. `ci-operator/config/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main__metal-5.0-nightly-x86.yaml` — adds the `windows-mssql-validation` job
2. `ci-operator/jobs/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main-presubmits.yaml` — generated by `make update`

**Target cluster profile:** `metal-perfscale-cpt`
