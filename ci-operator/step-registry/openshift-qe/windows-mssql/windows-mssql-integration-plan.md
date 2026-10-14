# Implementation Plan: Add Windows MSSQL Workload to OpenShift CI

## Context

**Goal:** Integrate the `windows-mssql` workload from [kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539) into the OpenShift release repository CI pipeline, following the pattern established by the windows-bootstorm workload in [PR #84309](https://github.com/openshift/release/pull/84309).

**Why:** Enable automated SQL Server TPC-C performance benchmarking on Windows VMs in OpenShift CI. This workload tests SQL Server database performance using HammerDB across multiple worker counts (1-32 concurrent workers) to measure scalability and regression detection.

**What the workload does:**
- Provisions Windows VMs with SQL Server and TPC-C database
- Runs HammerDB benchmarks with configurable worker counts (1, 2, 4, 8, 16, 32)
- Collects TPM (Transactions Per Minute) metrics per worker count
- Supports LVMS (per-node DataVolumes) and ODF (VolumeSnapshot) storage backends
- Uses virtctl scp/ssh for benchmark script transfer and execution
- Indexes results to Elasticsearch for Orion regression detection

**Target integration:** Create an on-demand test job using `metal-perfscale-jetlag` cluster profile. Once validated, can be migrated to `metal-perfscale-cpt` for production deployment.

**Storage strategy:** LVMS-only for initial implementation (using existing `openshift-qe-installer-bm-day2-lvms` setup). ODF support can be added in a follow-up PR with a separate job variant.

**Metrics:** Primary metric is TPM (Transactions Per Minute). NOPM (New Orders Per Minute) is not required.

**Testing approach:** Use jetlag exclusively for validation. CPT integration will be addressed after successful jetlag testing.

---

## Prerequisites

**CRITICAL DEPENDENCIES:** This implementation depends on two related PRs:

1. **[kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539)** - Windows MSSQL workload implementation
   - Must be **merged and tagged** in a kube-burner-ocp release
   - Provides the `windows-mssql` workload for SQL Server TPC-C benchmarking
   - Defines workload flags and implementation

2. **[Orion PR #487](https://github.com/cloud-bulldozer/orion/pull/487)** - Orion configuration for windows-mssql
   - Must be **merged** to enable regression detection
   - Provides the Orion config file for analyzing windows-mssql results
   - Defines metrics thresholds and change point detection

**Before implementation:**
1. ✅ Verify kube-burner-ocp PR #539 is merged and tagged
2. ✅ Note the kube-burner-ocp release version that includes the workload
3. ✅ Confirm the exact workload name and flag names from the merged code
4. ✅ Verify Orion PR #487 is merged with the jetlag/CPT configuration
5. ✅ Note the Orion config file path from PR #487

---

## Files to Create

### 1. Implementation Plan Documentation

**File:** `ci-operator/step-registry/openshift-qe/windows-mssql/windows-mssql-integration-plan.md`

Copy this plan document to the step-registry directory alongside the implementation files. This provides context for the implementation decisions, architecture, and validation steps.

---

### 2. Main Workload Step Registry

**Directory:** `ci-operator/step-registry/openshift-qe/windows-mssql/`

#### `openshift-qe-windows-mssql-ref.yaml`
Step definition with environment variables and configuration:
- **Image:** `ocp-qe-perfscale-ci:latest`
- **Timeout:** `5h` (longer than windows-bootstorm's 3h due to multiple benchmark iterations)
- **Credentials:**
  - ES credentials: `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds` → `/secret`
  - Windows image URL: `perfci/benchmark-runner/windows_url` → `/secret-perfci`

**Key Environment Variables:**

| Variable | Default | Purpose |
|----------|---------|---------|
| `WORKLOAD` | `windows-mssql` | Workload name for kube-burner-ocp |
| `STORAGE_CLASS` | `lvms-nvme` | StorageClass for DataVolumes (LVMS) |
| `ACCESS_MODE` | `RWO` | PVC access mode (Read-Write-Once for LVMS) |
| `EVICTION_STRATEGY` | `None` | VM eviction strategy (no live migration for LVMS) |
| `PER_NODE_DV` | `true` | Create one source DV per worker node (LVMS optimization) |
| `USE_SNAPSHOT` | `false` | Use VolumeSnapshot API (for future ODF support) |
| `VM_CPUS` | `32` | CPU cores for SQL Server VM |
| `VM_MEMORY` | `32Gi` | Memory allocation for SQL Server VM |
| `VMS_PER_NODE` | `1` | Number of VMs per worker node (intensive workload) |
| `DATABASE_SIZE` | `96` | TPC-C warehouses (database size) |
| `WORKER_COUNTS` | `1,2,4,8,16,32` | HammerDB worker counts to test |
| `ITERATIONS` | `2` | Benchmark iterations per worker count |
| `PROFILE_TYPE` | `both` | kube-burner indexing profile type |
| `E2E_VERSION` | `default` | e2e-benchmarking tag to use |
| `KUBE_BURNER_VERSION` | `default` | kube-burner-ocp version override |
| `GC` | `true` | Clean up resources after run |
| `ENABLE_LOCAL_INDEX` | `false` | Enable local indexing for artifacts |

**Pattern reference:** Follow `openshift-qe-virt-density-ref.yaml` structure with windows-mssql-specific variables.

#### `openshift-qe-windows-mssql-commands.sh`
Workload execution script following windows-bootstorm pattern:

1. **Setup:**
   - Configure ES credentials from `/secret`
   - Retrieve Windows image URL from `/secret-perfci` Vault secret
   - Clone e2e-benchmarking repository
   - Navigate to `e2e-benchmarking/workloads/kube-burner-ocp-wrapper`

2. **Cluster Stabilization:**
   - Wait for nodes to be Ready (900s timeout, 20s intervals)
   - Wait for MachineConfigPool worker to be stable (not Updating/Degraded)
   - Exit with error if cluster doesn't stabilize

3. **Virtctl Installation:**
   - Get virtctl download URL from `consoleclidownload/virtctl-clidownloads-kubevirt-hyperconverged`
   - Download, extract, and add to PATH
   - Verify with `virtctl version --client`

4. **Workload Execution:**
   ```bash
   export WORKLOAD=windows-mssql
   export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"
   export EXTRA_FLAGS="--metrics-profile metrics.yml,cnv-metrics.yml \
                       --gc-metrics=false \
                       --windows-image-url=${WINDOWS_IMAGE_URL} \
                       --vms-per-node=${VMS_PER_NODE} \
                       --storage-class=${STORAGE_CLASS} \
                       --access-mode=${ACCESS_MODE} \
                       --eviction-strategy=${EVICTION_STRATEGY} \
                       --profile-type=${PROFILE_TYPE} \
                       --per-node-dv \
                       --vm-cpus=${VM_CPUS} \
                       --vm-memory=${VM_MEMORY} \
                       --database-size=${DATABASE_SIZE} \
                       --worker-counts=${WORKER_COUNTS} \
                       --iterations=${ITERATIONS}"
   
   [[ "${ENABLE_LOCAL_INDEX}" == "true" ]] && EXTRA_FLAGS+=" --local-indexing"
   [[ "${USE_SNAPSHOT}" == "true" ]] && EXTRA_FLAGS+=" --use-snapshot"
   
   ./run.sh
   ```

5. **Artifact Collection:**
   - Copy `collected-metric*` folders to `${ARTIFACT_DIR}/` if local indexing enabled

**Pattern reference:** Adapt from `openshift-qe-virt-density-commands.sh` with SQL-specific flags.

#### `openshift-qe-windows-mssql-ref.metadata.json`
```json
{
  "path": "openshift-qe/windows-mssql/openshift-qe-windows-mssql-ref.yaml",
  "owners": {
    "approvers": ["perfscale-ocp-approvers"],
    "reviewers": ["perfscale-ocp-reviewers"]
  }
}
```

#### `OWNERS`
Create as symlink to parent OWNERS file:
```bash
ln -s ../OWNERS ci-operator/step-registry/openshift-qe/windows-mssql/OWNERS
```

---

### 3. Orion Regression Detection Wrapper

**Directory:** `ci-operator/step-registry/openshift-qe/orion/windows-mssql/`

#### `openshift-qe-orion-windows-mssql-ref.yaml`
Orion wrapper step definition:
- **Image:** `ocp-qe-perfscale-ci:latest`
- **Timeout:** `6h` (workload 5h + 1h buffer for analysis)
- **Commands:** `openshift-qe-orion-windows-mssql-commands.sh` (symlink to shared script)
- **Credentials:** Same ES credentials as main workload (two mounts: `/secret/qe` and `/secret/internal`)

**Key Environment Variables:**
- `ORION_CONFIG: "examples/metal-perfscale-jetlag-windows-mssql.yaml"` - Orion config file in orion repo (use jetlag or cpt based on cluster profile)
- `ES_TYPE: "qe"` - ES type for data retrieval
- `LOOKBACK: "15"` - Days to look back for regression analysis
- `RUN_ORION: "false"` - Default false, overridden by job env var
- `DISPLAY: "ocpVirtVersion"` - Custom metadata field to display
- `CHANGE_POINT_REPOS: "kube-burner/kube-burner,kube-burner/kube-burner-ocp,cloud-bulldozer/e2e-benchmarking,openshift/release"` - Repos to monitor for changes

**Note:** The ORION_CONFIG path should match the cluster profile being used (jetlag vs cpt).

**Pattern reference:** Copy structure from `openshift-qe-orion-virt-density-ref.yaml`, update ORION_CONFIG path.

#### `openshift-qe-orion-windows-mssql-commands.sh`
Create as symlink to shared Orion script:
```bash
ln -s ../openshift-qe-orion-commands.sh \
      ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-commands.sh
```

**Pattern:** All Orion wrappers use the same `openshift-qe-orion-commands.sh` script via symlink.

#### `openshift-qe-orion-windows-mssql-ref.metadata.json`
```json
{
  "path": "openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-ref.yaml",
  "owners": {
    "approvers": ["perfscale-ocp-approvers"],
    "reviewers": ["perfscale-ocp-reviewers"]
  }
}
```

#### `OWNERS`
Create as symlink to parent orion OWNERS file:
```bash
ln -s ../../OWNERS ci-operator/step-registry/openshift-qe/orion/windows-mssql/OWNERS
```

---

## Files to Modify

### 4. CI Job Configuration

**File:** `ci-operator/config/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main__metal-x86.yaml`

**Modification:** Create a new on-demand test job for windows-mssql workload validation using jetlag cluster profile.

**Add new job:**
```yaml
- always_run: false
  as: windows-mssql-validation
  capabilities:
  - intranet
  restrict_network_access: false
  steps:
    cluster_profile: metal-perfscale-jetlag
    env:
      CNV_VERSION: "4.18"  # Or appropriate version
      ENABLE_LOCAL_INDEX: "true"
      RUN_ORION: deferred
      VERSION: "4.18"
    test:
    - ref: openshift-qe-installer-bm-day2-label
    - ref: openshift-qe-installer-bm-day2-lvms
    - ref: openshift-qe-installer-bm-day2-cnv
    - ref: openshift-qe-windows-mssql
    - ref: openshift-qe-orion-windows-mssql
    - ref: openshift-qe-orion-report
    workflow: openshift-qe-installer-bm-deploy
```

**Future CPT Integration (After Jetlag Validation):**
<!--
Once validated on jetlag, add to metal-5.0-nightly-x86.yaml daily-virt-6nodes job:

test:
  - ref: openshift-qe-installer-bm-day2-label
  - ref: openshift-qe-installer-bm-day2-lvms
  - ref: openshift-qe-installer-bm-day2-cnv
  - ref: openshift-qe-virt-udn-density
  - ref: openshift-qe-orion-virt-udn-density
  - ref: openshift-qe-virt-density-nomount
  - ref: openshift-qe-orion-virt-density-nomount
  - ref: openshift-qe-windows-bootstorm  # If PR #84309 merged
  - ref: openshift-qe-orion-windows-bootstorm
  - ref: openshift-qe-windows-mssql  # ADD AFTER JETLAG VALIDATION
  - ref: openshift-qe-orion-windows-mssql
  - ref: openshift-qe-orion-report

cluster_profile: metal-perfscale-cpt
-->

---

## Reused Existing Components

The implementation leverages these existing step-registry components:

1. **`openshift-qe-installer-bm-day2-lvms`** - LVMS storage setup (already in daily-virt-6nodes job)
2. **`openshift-qe-installer-bm-day2-cnv`** - CNV/OpenShift Virtualization setup (already in job)
3. **`openshift-qe-orion-commands.sh`** - Shared Orion execution script (via symlink)
4. **`openshift-qe-orion-report`** - Final Orion report aggregation (already in job)
5. **`openshift-qe-installer-bm-gather-extra`** - Extra artifact collection (post step)
6. **`openshift-qe-installer-bm-must-gather`** - Must-gather collection (post step)

**Credentials used:**
- `ocp-perfscale-cpt/ocp-qe-perfscale-es-creds` - Elasticsearch credentials (already mounted in other steps)
- `perfci/benchmark-runner/windows_url` - Windows image URL from Vault (same as windows-bootstorm)

---

## Implementation Approach

### Storage Backend Configuration

**Phase 1: LVMS Only (This PR)**
- Use LVMS with per-node DataVolumes (`--per-node-dv`)
- Storage class: `lvms-nvme` (configured by LVMS day2 step)
- Access mode: `RWO` (Read-Write-Once)
- Eviction strategy: `None` (no live migration with LVMS)
- Leverage existing `openshift-qe-installer-bm-day2-lvms` setup
- Testing on metal-perfscale-jetlag cluster profile

**Phase 2: ODF Support (Future PR)**
- Create a separate job variant (e.g., `daily-virt-6nodes-odf`)
- Override environment variables:
  - `STORAGE_CLASS: "ocs-storagecluster-ceph-rbd-virtualization"`
  - `ACCESS_MODE: "RWX"`
  - `EVICTION_STRATEGY: "LiveMigrate"`
  - `PER_NODE_DV: "false"`
  - `USE_SNAPSHOT: "true"`
- Use `openshift-qe-installer-bm-day2-odf` instead of LVMS setup step

### Default Configuration Rationale

**VM Resources:**
- **32 CPU / 32Gi memory** - SQL Server benefits from high CPU for parallel query processing
- **1 VM per node** - Focus on intensive single-VM workload vs. density testing

**Benchmark Configuration:**
- **96 warehouses** - Moderate TPC-C database size (~10GB) for reasonable test duration
- **Worker counts: 1,2,4,8,16,32** - Tests scalability from single-threaded to highly parallel
- **2 iterations** - Balance statistical significance with test duration

**Expected Duration:**
- VM provisioning: ~15 minutes
- SQL Server + TPC-C setup: ~20 minutes
- Benchmarks: 6 worker counts × 2 iterations × ~15 min/iteration = ~180 minutes (3 hours)
- Teardown: ~10 minutes
- **Total: ~4 hours** (5h timeout provides 1h buffer)

**Metrics:**
- Profiles: `metrics.yml,cnv-metrics.yml` (matches windows-bootstorm)
- Indexing: TPM (Transactions Per Minute) and latency metrics per worker count
- Multi-document indexing: Separate ES documents per worker count for scalability analysis

---

## Verification Steps

After implementation, test the changes end-to-end:

### 1. Configuration Validation
```bash
# Regenerate CI configs
make update

# Validate step registry
make validate-step-registry

# Check CI config
make checkconfig
```

### 2. Rehearsal Testing
```bash
# Test job generation
make jobs WHAT=openshift-eng-ocp-perfscale-main__metal-x86

# Run rehearsal (requires cluster access)
# This will be done automatically by rehearsal bot on PR
```

**Important:** The rehearsal will only validate configuration syntax and step references. It will NOT run the full 5-hour workload.

### 3. Manually Triggering the Job (After PR Merge)

Since the job is configured with `always_run: false`, it is an **on-demand job** that must be triggered manually.

**Option A: Using Prow Commands (Recommended)**

1. Create a test PR in **any OpenShift component repository** (or use an existing PR)
2. Add a comment to trigger the job:
   ```
   /test windows-mssql-validation
   ```
3. Monitor the job execution in the Prow dashboard
4. Check job logs and artifacts at the provided URL

**Option B: Using Gangway UI**

1. Navigate to the Gangway UI: https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/
2. Authenticate with your Red Hat credentials
3. Search for job: `windows-mssql-validation`
4. Select the job and click "Submit"
5. Fill in any required parameters (usually none for this job)
6. Monitor execution in Prow dashboard

**Option C: Direct Prow API (Advanced)**

```bash
# Create a ProwJob YAML and submit via kubectl
# Requires cluster access and proper authentication
```

**What Happens When Triggered:**

1. **Cluster provisioning** - Prow allocates a 6-node bare-metal cluster from `metal-perfscale-jetlag` pool (~30-45 min)
2. **Workflow execution** - Runs `openshift-qe-installer-bm-deploy` workflow to install OpenShift
3. **Day2 setup** - Installs LVMS and CNV operators (~15-20 min)
4. **Workload execution** - Runs windows-mssql benchmark (~4 hours)
5. **Orion analysis** - Analyzes results and detects regressions (~15-30 min)
6. **Cleanup** - Deprovisions cluster and collects artifacts

**Total execution time:** ~5-6 hours

**Monitoring the Job:**

1. **Prow Dashboard:** View real-time status and logs
2. **Artifacts:** Check `${ARTIFACT_DIR}/` for metrics and logs after completion
3. **Elasticsearch:** Query for indexed results:
   ```bash
   curl -X GET "https://$ES_HOST/ripsaw-kube-burner-*/_search" \
     -H 'Content-Type: application/json' \
     -d '{"query": {"match": {"workload": "windows-mssql"}}}'
   ```

### 4. Integration Testing Checklist
- [ ] VM provisions successfully with LVMS storage (2 disks: root + data)
- [ ] Windows OS boots and SQL Server is accessible via virtctl
- [ ] TPC-C database created with 96 warehouses
- [ ] HammerDB executes benchmarks across all worker counts (1,2,4,8,16,32)
- [ ] Each worker count runs 2 iterations
- [ ] TPM results indexed to Elasticsearch with correct schema
- [ ] Multiple ES documents created (one per worker count)
- [ ] Orion detects and analyzes results
- [ ] Orion report includes windows-mssql workload
- [ ] Artifacts collected in `${ARTIFACT_DIR}/`
- [ ] Workload cleanup completes successfully (if GC=true)
- [ ] Job completes within 5h timeout

### 5. Metrics Validation
Check Elasticsearch for indexed results:
```bash
# Query ES for windows-mssql results
curl -X GET "https://$ES_HOST/ripsaw-kube-burner-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match": {"workload": "windows-mssql"}}}'
```

Expected metrics per worker count:
- `tpm` - Transactions Per Minute
- `vm_boot_time` - VM startup time
- CNV-specific metrics from `cnv-metrics.yml`

---

## Branch Creation and Workflow

### Branch Naming
Create a new branch following OpenShift conventions:
```bash
git checkout -b add-windows-mssql-workload
```

### Commit Strategy
Create logical commits:
1. Add main workload step-registry (windows-mssql/)
2. Add Orion wrapper step-registry (orion/windows-mssql/)
3. Update CI config (daily-virt-6nodes job)
4. Regenerate configs (make update)

### Commit Message Pattern
Follow OpenShift commit style:
```
Add windows-mssql workload validation job

Integrates the windows-mssql workload (SQL Server TPC-C benchmarking)
from kube-burner-ocp into OpenShift CI following the windows-bootstorm
pattern.

- Creates step-registry refs for windows-mssql workload execution
- Adds Orion regression detection wrapper
- Creates on-demand validation job using metal-perfscale-jetlag
- Supports LVMS storage with per-node DataVolumes
- Configures 32 CPU/32Gi VMs with 96 TPC-C warehouses
- Tests scalability across worker counts: 1,2,4,8,16,32
- Indexes TPM metrics to Elasticsearch

Related PRs:
- kube-burner/kube-burner-ocp#539 (workload implementation)
- cloud-bulldozer/orion#487 (Orion configuration)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

---

## Dependencies and Blockers

### Critical Blockers
1. **[kube-burner-ocp PR #539](https://github.com/kube-burner/kube-burner-ocp/pull/539)** - Must be merged and tagged
   - Verify workload name is `windows-mssql`
   - Confirm all flag names (`--database-size`, `--worker-counts`, `--iterations`, `--vm-cpus`, `--vm-memory`, `--use-snapshot`)
   - Note the release version/tag

2. **[Orion PR #487](https://github.com/cloud-bulldozer/orion/pull/487)** - Must be merged
   - Provides Orion config for windows-mssql workload
   - Defines metrics to track (tpm, vm_boot_time)
   - Sets regression detection thresholds
   - Configures metadata fields
   - Note the config file path from PR #487

### Optional Dependencies
3. **PR #84309 (windows-bootstorm)** - Reference pattern, not required
   - If not merged yet, adapt pattern from existing virt workloads
   - Add windows-mssql steps at end of virt workload sequence

### Infrastructure Requirements
- **6-node bare-metal cluster** (metal-perfscale-jetlag profile)
- **LVMS operator** (installed by day2 setup step)
- **CNV/OpenShift Virtualization** (installed by day2 setup step)
- **Windows image** (available via Vault secret)
- **Elasticsearch cluster** (for metrics indexing)

**Note:** After successful jetlag validation, can migrate to metal-perfscale-cpt for production.

---

## Cost Analysis

### Claude API Token Cost (Planning + Implementation)

**Initial Estimate:**
- Planning: ~$0.51
- Implementation: ~$0.60
- **Total Estimated: $1.10 - $1.50**

**Actual Cost: $7.58**

**Why Higher Than Estimated:**
The actual cost was significantly higher due to:
1. **Multiple exploration agents** - Ran 2 parallel Explore agents in Phase 1 to understand codebase patterns
2. **Design agent** - Launched Plan agent in Phase 2 to design implementation approach
3. **Extended planning session** - Multiple clarifications, plan updates, and user questions
4. **Additional file operations** - More file reads and pattern analysis than initially estimated
5. **Make command execution** - Long-running `make update` and `make checkconfig` processes
6. **Iterative refinements** - Plan updates for jetlag cluster profile, NOPM metric removal, cost analysis additions

**Breakdown:**
- Token usage: ~124K tokens (vs estimated 162K)
- Multi-agent workflow added substantial overhead
- Complex planning sessions typically cost **$5-10** vs simple implementations at $1-2

**Lesson learned:** Multi-agent planning with exploration and design phases costs 5-7x more than simple file creation.

### Infrastructure Cost (Per Job Execution)

**Direct financial cost:** $0
- Bare-metal clusters are pre-allocated Red Hat internal infrastructure
- No cloud compute charges (on-premise hardware)
- Shared resource pool already budgeted
- All licenses (OpenShift, Windows, SQL Server) included

**Opportunity cost:**
- 6-node cluster occupied for 5-6 hours per execution
- Resource unavailable for other jobs during runtime
- Jetlag pool has finite capacity - jobs may queue

**Expected execution frequency:**
- On-demand job (manual trigger only)
- Estimated: 1-2 runs per week initially, then as-needed

---

## Future Enhancements

### ODF Storage Backend
Create a follow-up PR with:
- New job: `daily-virt-6nodes-odf` or `windows-mssql-odf-validation`
- ODF setup: `openshift-qe-installer-bm-day2-odf`
- Environment overrides for ODF storage configuration
- Compare LVMS vs. ODF performance characteristics

### Workload Configuration Variants
Add job variants to test different configurations:
- **Scale test:** Increase `VMS_PER_NODE` to test multiple VMs
- **Large database:** Increase `DATABASE_SIZE` to 200+ warehouses
- **Extended run:** More iterations or worker counts for statistical significance
- **Resource variants:** Test different CPU/memory allocations

### Metrics and Analysis
- Add custom Grafana dashboards for SQL Server metrics
- Integrate with TestGrid for historical trend analysis
- Add Orion dashboards specific to database workloads
- Track cost-per-transaction metrics

---

## Summary

This plan implements the windows-mssql workload integration following the established windows-bootstorm pattern:

**Creates 9 new files:**
1. `ci-operator/step-registry/openshift-qe/windows-mssql/windows-mssql-integration-plan.md` (this plan document)
2. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-ref.yaml`
3. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-commands.sh`
4. `ci-operator/step-registry/openshift-qe/windows-mssql/openshift-qe-windows-mssql-ref.metadata.json`
5. `ci-operator/step-registry/openshift-qe/windows-mssql/OWNERS` (symlink)
6. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-ref.yaml`
7. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-commands.sh` (symlink)
8. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/openshift-qe-orion-windows-mssql-ref.metadata.json`
9. `ci-operator/step-registry/openshift-qe/orion/windows-mssql/OWNERS` (symlink)

**Modifies 1 file:**
1. `ci-operator/config/openshift-eng/ocp-perfscale/openshift-eng-ocp-perfscale-main__metal-x86.yaml` - Add new `windows-mssql-validation` job

**Reuses existing infrastructure:**
- LVMS day2 setup, CNV day2 setup, Orion scripts, ES credentials, Windows image secrets

**Target cluster profile:** `metal-perfscale-jetlag` (validated before CPT migration)

**Timeline:** ~5h workload runtime per execution
