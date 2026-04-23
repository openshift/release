# RHDH CI Configuration

## Available Skills

Skills in `.claude/skills/` are loaded on demand by the agent. Use them when working with RHDH OCP version management in this repository.

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

## New Release Branch Checklist

When creating a new release branch (e.g., `release-1.11`):

### Slack Webhook

1. Create a new Slack channel following the established naming scheme (see existing channels in the [Nightly Test Alerts Slack app](https://api.slack.com/apps/A08U4AP1YTY/incoming-webhooks) for reference).
2. In the same Slack app, create a new incoming webhook for the newly created channel.
3. Store the webhook URL in the vault as `SLACK_ALERTS_WEBHOOK_URL_X_Y` (e.g., `SLACK_ALERTS_WEBHOOK_URL_1_11` for `release-1.11`).
4. The `redhat-developer-rhdh-send-alert` step automatically detects the release version from `JOB_NAME` and looks for the versioned webhook file at `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL_X_Y`. If not found, it falls back to `/tmp/secrets/SLACK_ALERTS_WEBHOOK_URL`.

### Job Concurrency

After running `make update` for the new release branch, manually set `max_concurrency` on presubmit jobs in `ci-operator/jobs/redhat-developer/rhdh/`. This value is not auto-generated for new jobs. Use the main branch presubmits as reference for the correct values.
