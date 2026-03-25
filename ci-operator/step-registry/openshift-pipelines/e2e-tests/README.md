# openshift-pipelines-e2e-tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Secrets](#secrets)
- [Custom Images](#custom-images)

## Purpose

Runs the OpenShift Pipelines **full e2e test suite** against a provisioned cluster.
This step is intentionally separate from `openshift-pipelines-tests` (interop sanity)
so that interop periodic jobs are never affected by changes to the e2e suite.

## Process

1. Export every file under `/var/run/secrets/openshift-pipelines-e2e-credentials/` as an
   environment variable (uppercased filename → value), making cloud/registry credentials
   available to gauge tests.
2. Read the cluster console URL from `$SHARED_DIR/console.url`, derive `API_URL`,
   and set `KUBECONFIG`, `gauge_reports_dir`, `overwrite_reports`, and `GOPROXY`.
3. Configure gauge runner timeouts (`runner_connection_timeout 600000`,
   `runner_request_timeout 300000`) to prevent connection errors on large clusters.
4. Log in to the cluster — using `kubeadmin` password when available (IPI/UPI),
   otherwise evaluating `$SHARED_DIR/api.login` (ROSA / Hypershift).
5. Reinstall the `xml-report` gauge plugin at a pinned version (`0.5.3`).
6. Iterate over `PIPELINES_TEST_SPECS` (`;`-separated) and run each spec with
   `--tags "${TEST_TAGS} & !tls"`, up to 3 retries; errors are non-fatal (`|| true`).
7. Run `specs/operator/rbac.spec` separately with `--tags "${TEST_TAGS}"` (non-fatal).
8. Rename all XML files in `$ARTIFACT_DIR/xml-report/` to
   `$ARTIFACT_DIR/junit_test_result<N>.xml` for Prow artifact ingestion.

## Prerequisite(s)

### Infrastructure

- A provisioned cluster (IPI, ROSA Classic, or ROSA Hypershift).

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TEST_TAGS` | `e2e` | Gauge tag filter applied to all spec runs. |
| `PIPELINES_TEST_SPECS` | `specs/pipelines/;specs/triggers/;specs/metrics/;specs/operator/addon.spec;specs/operator/auto-prune.spec` | Semi-colon-separated list of gauge spec paths to run. |

### Secrets

| Secret | Mount Path | Description |
|---|---|---|
| `openshift-pipelines-e2e-credentials` | `/var/run/secrets/openshift-pipelines-e2e-credentials/` | Cloud provider and registry credentials required by the e2e test suite. Each file is exported as an environment variable. |

## Custom Images

- `openshift-pipelines-runner` — built from the `Dockerfile` in the
  `openshift-pipelines/release-tests` repository. Contains the gauge binary,
  all test specs, and required tooling.
