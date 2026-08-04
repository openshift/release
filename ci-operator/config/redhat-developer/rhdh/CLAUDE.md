# RHDH CI Configuration

## Available Skills

Skills in `.claude/skills/` are loaded on demand by the agent. Use them when working with RHDH version management in this repository.

### `rhdh-ocp-lifecycle` — Check RHDH & OCP version support

Query the Red Hat Product Life Cycles API to determine which OCP versions are supported by active RHDH releases and which are end-of-life. Shows both RHDH compatibility (`openshift_compatibility` field) and OCP upstream support (including EUS phases). Supports OCP 4.x and future 5.x+.

**Scripts**: `check-ocp-lifecycle.sh [--version X.Y] [--rhdh-version X.Y] [--rhdh-only]`

### `rhdh-ocp-pool` — Manage OCP Hive ClusterPools

List existing RHDH OCP cluster pools or generate a new pool for a target OCP version. Covers Hive ClusterPools for OCP only — K8s platform clusters (AKS, EKS, GKE) use MAPT and OSD-GCP uses a separate claim workflow. The generation script looks up `imageSetRef` from other pools across the entire repo to ensure alignment.

**Scripts**: `list-cluster-pools.sh`, `generate-cluster-pool.sh --version X.Y`

### `rhdh-ocp-tests` — Manage OCP test entries

List, generate, add, and remove OCP-versioned test entries (`e2e-ocp-*`) in CI config files. Covers only OCP cluster-claim tests, not K8s platform tests (AKS, EKS, GKE, OSD). OCP versions are extracted from `cluster_claim.version` (the source of truth), not from test names.

**Scripts**: `list-ocp-test-configs.sh [--branch <name>]`, `generate-test-entry.sh --version X.Y --branch <name>`

### `rhdh-ocp-coverage` — Analyze OCP version coverage

Cross-reference cluster pools, CI test configs, RHDH lifecycle, and OCP lifecycle to find gaps, stale configs, and mismatches. Checks two dimensions: OCP lifecycle (is the OCP version still supported?) and RHDH compatibility (does RHDH officially support this OCP version?). OCP-EOL versions are never recommended for new pools or tests, even if RHDH still lists them.

**Scripts**: `analyze-coverage.sh [--pool-dir <path>] [--config-dir <path>]`

### `rhdh-decommission-release` — Decommission EOL release branch

Remove all CI configuration for an end-of-life RHDH release branch: CI config file, generated Prow jobs, and branch protection entry.

### `rhdh-aks-lifecycle` — Check AKS K8s version support

Query the official AKS release status API (`releases.aks.azure.com`) for supported K8s versions (major.minor) and compare against the versions configured per branch in CI config files. Cross-verifies with endoflife.date for EOL dates.

**Scripts**: `check-aks-lifecycle.sh [--mapt-ref <path>] [--test-pattern <regex>]`

### `rhdh-aks-tests` — Manage AKS test entries and K8s version

List AKS test entries (`e2e-aks-*`) across RHDH release branches and update the K8s version. The version is set per branch via `MAPT_KUBERNETES_VERSION` in each CI config file's `steps.env`. `make update` is not required for version changes.

**Scripts**: `list-k8s-test-configs.sh --pattern <regex>`

### `rhdh-eks-lifecycle` — Check EKS K8s version support

Query the official AWS EKS docs source (`awsdocs/amazon-eks-user-guide` on GitHub) for supported K8s versions (standard/extended) and release calendar. Cross-verifies with endoflife.date for EOL dates.

**Scripts**: `check-eks-lifecycle.sh [--mapt-ref <path>] [--test-pattern <regex>]`

### `rhdh-eks-tests` — Manage EKS test entries and K8s version

List EKS test entries (`e2e-eks-*`) across RHDH release branches and update the K8s version. The version is set per branch via `MAPT_KUBERNETES_VERSION` in each CI config file's `steps.env`. `make update` is not required for version changes.

**Scripts**: `list-k8s-test-configs.sh --pattern <regex>`

### `rhdh-gke-lifecycle` — Check GKE K8s version support

Query the endoflife.date API (auto-scraped from Google's GKE release schedule page) for supported K8s versions with standard/maintenance status and EOL dates. GKE uses a long-running static cluster whose version is not managed in CI config.

**Scripts**: `check-gke-lifecycle.sh`

### `rhdh-gke-tests` — Manage GKE test entries

List GKE test entries (`e2e-gke-*`) across RHDH release branches. Unlike AKS/EKS, GKE uses a pre-existing static cluster — version upgrades are performed via the GCP Console. `make update` is not required.

**Scripts**: `list-k8s-test-configs.sh --pattern <regex>`

## New Release Branch Checklist

When creating a new release branch (e.g., `release-1.11`):

### Slack Webhook

1. Create a new Slack channel named `#rhdh-e2e-alerts-X-Y` (e.g., `#rhdh-e2e-alerts-1-11` for `release-1.11`). See existing channels in the [Nightly Test Alerts Slack app](https://api.slack.com/apps/A08U4AP1YTY/incoming-webhooks) for reference.
2. In the same Slack app, create a new incoming webhook for the newly created channel.
3. Store the webhook URL in the vault as `SLACK_ALERTS_WEBHOOK_URL_X_Y` (e.g., `SLACK_ALERTS_WEBHOOK_URL_1_11` for `release-1.11`).
4. The `redhat-developer-rhdh-send-alert` step automatically detects the release version from `JOB_NAME` and looks for the versioned webhook file at `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL_X_Y`. If not found, it falls back to `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL`.
5. Update the `reporter_config.channel` in the new release CI config YAML to use `#rhdh-e2e-alerts-X-Y` (e.g., `#rhdh-e2e-alerts-1-11`). This is the Prow-level Slack reporter — separate from the `send-alert` step — that fires on CI infrastructure errors and (for `auth-providers` and `upgrade` tests) on success/failure. The `main` branch uses `#rhdh-e2e-alerts`.

### Job Concurrency

After running `make update` for the new release branch, manually set `max_concurrency` on presubmit jobs in `ci-operator/jobs/redhat-developer/rhdh/`. This value is not auto-generated for new jobs. Use the main branch presubmits as reference for the correct values.
