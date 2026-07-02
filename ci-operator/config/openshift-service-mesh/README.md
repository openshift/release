# OpenShift Service Mesh CI

Quick reference for CI jobs across all OSSM repositories.

| Repo | Branches |
|------|----------|
| [federation](federation/) | master |
| [istio](istio/) | master, release-1.x |
| [proxy](proxy/) | release-1.x |
| [sail-operator](sail-operator/) | main, release-3.x |
| [ztunnel](ztunnel/) | release-1.x |

## Jobs

### federation

| Job | Type | OCP cluster |
|-----|------|-------------|
| `e2e-integration` | presubmit | yes |
| `push-image` | postsubmit | no |

### istio

| Job | Type | OCP cluster |
|-----|------|-------------|
| `lint` | presubmit | no |
| `unit-and-gencheck` | presubmit | no |
| `istio-integration-{pilot,telemetry,security,ambient,helm}` | presubmit | yes |
| `istio-integration-sail-{pilot,telemetry,security,ambient}` | presubmit | yes |
| `sync-upstream-istio-master` | periodic | no |

### proxy

| Job | Type | OCP cluster |
|-----|------|-------------|
| `unit` / `unit-arm` | presubmit | no |
| `envoy` | presubmit (`always_run: false`) | yes |
| `copy-artifacts-gcs` / `copy-artifacts-gcs-arm` | postsubmit | no |
| `update-istio` | postsubmit | no |

### sail-operator

| Job | Type | OCP cluster | Notes |
|-----|------|-------------|-------|
| `unit` / `integration` / `gencheck` / `lint` | presubmit | no | |
| `e2e-ocp` | presubmit (`always_run: false`) | yes (amd64) | |
| `scorecard` | presubmit (`always_run: false`) | yes | only when `bundle/` changes |
| `istio-pr-perfscale` | presubmit (`always_run: false`) | yes | ~4h runtime |
| `e2e-ocp-arm` | postsubmit | yes (arm64) | use `e2e-ocp-arm-retest` to rerun |
| `e2e-next-ocp` | postsubmit | yes (amd64) | main/ocp-4.23 only; use `e2e-next-ocp-retest` to rerun |
| `sync-upstream` | periodic | no | per release branch |
| `istio-periodic-perfscale` | periodic | yes | 1st and 15th of month |
| `cr-servicemesh-aws` / `servicemesh-aws-fips` | periodic | yes | lp-interop |

### ztunnel

| Job | Type | OCP cluster |
|-----|------|-------------|
| `cargo-build` | presubmit | no |
| `cargo-build-and-push` | postsubmit | no |
| `update-istio` | postsubmit | no |

## Triggering jobs manually

Presubmit jobs with `always_run: false` can be triggered from a PR comment:

```
/test <variant>-<job>
```

Postsubmit jobs cannot be triggered via `/test`. Use the dedicated retest presubmits in sail-operator:

| Postsubmit | Trigger via |
|-----------|-------------|
| `e2e-ocp-arm` | `/test ocp-4.22-e2e-ocp-arm-retest` |
| `e2e-next-ocp` | `/test ocp-4.23-e2e-next-ocp-retest` |

## Slack notifications

| Channel | Jobs |
|---------|------|
| `#team-ossm-quality` | `e2e-ocp-arm`, `e2e-next-ocp`, `istio-pr-perfscale`, `istio-periodic-perfscale`, `cr-servicemesh-aws`, `servicemesh-aws-fips` |
| `#team-ossm-release-maintenance` | `sync-upstream` (all release branches) |
