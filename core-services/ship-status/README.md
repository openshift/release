Configuration files for the SHIP Status and Availability Dashboard.
More information can be found at: https://github.com/openshift-eng/ship-status-dash/blob/main/README.md

## Onboarding a new build cluster

Adding a new build cluster to SHIP Status monitoring requires changes across several files. The order below reflects dependency order (credentials must exist before monitoring can use them).

### 1. Credentials

These should merge first so the component-monitor has kubeconfigs for the new cluster.

- **`core-services/ci-secret-generator/_config.yaml`** -- add the cluster to the `ship-status-dash-component-monitor` item's `cluster` list so tokens and kubeconfigs are generated.
- **`core-services/ci-secret-bootstrap/_config.yaml`** -- add `buildNN.config` and `sa.component-monitor.buildNN.token.txt` entries to the `component-monitor-kubeconfigs` secret block, following the existing pattern.

### 2. Canary job

The component-monitor's `junit_monitor` probe checks canary job results. Without the job, the probe errors and the cluster never reports status.

- **`ci-operator/jobs/infra-build-farm-periodics.yaml`** -- add a `periodic-build-farm-canary-buildNN` entry matching the existing pattern (runs every 15 min, 10m timeout, no rehearsal label).
- **`core-services/sanitize-prow-jobs/_config.yaml`** -- pin the canary job to its cluster under the `buildNN: jobs:` section. Without this, the job runs on the default cluster instead.

### 3. Monitoring config

- **`hack/generate-build-farm-monitor-config.py`** -- add the cluster to `CONSOLE_URLS` (with its console URL) and extend `BUILD_ORDER`.
- Run `python3 hack/generate-build-farm-monitor-config.py` to regenerate:
  - **`core-services/ship-status/component-monitor-config.yaml`**
  - **`core-services/ship-status/dashboard-config.yaml`**

The generator reads `core-services/sanitize-prow-jobs/_clusters.yaml` to determine which clusters are blocked (commented out) vs active.

### SA and RBAC (no per-cluster action needed)

The `component-monitor` ServiceAccount and its `cluster-monitoring-view` / route-reader RBAC are defined in `clusters/build-clusters/build-shared/ship-status/` and applied to all build clusters automatically via the build-shared mechanism.
