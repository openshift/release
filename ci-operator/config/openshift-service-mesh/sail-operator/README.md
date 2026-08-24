# OpenShift Service Mesh CI

Maintenance documentation for OpenShift Service Mesh CI jobs. Contains essential information not available in the configuration files themselves. Please add here any information that may help future maintainers.

## CI Jobs Overview

Quick reference for CI jobs across all OSSM repositories.

| Repo | Branches |
|------|----------|
| [federation](../federation/) | master |
| [istio](../istio/) | master, release-1.x |
| [proxy](../proxy/) | release-1.x |
| [sail-operator](./) | main, release-3.x |
| [ztunnel](../ztunnel/) | release-1.x |

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

### Triggering jobs manually

Presubmit jobs with `always_run: false` can be triggered from a PR comment:

```
/test <variant>-<job>
```

Postsubmit jobs cannot be triggered via `/test`. Use the dedicated retest presubmits in sail-operator:

| Postsubmit | Trigger via |
|-----------|-------------|
| `e2e-ocp-arm` | `/test ocp-4.22-e2e-ocp-arm-retest` |
| `e2e-next-ocp` | `/test ocp-4.23-e2e-next-ocp-retest` |

### Slack notifications

| Channel | Jobs |
|---------|------|
| `#team-ossm-quality` | `e2e-ocp-arm`, `e2e-next-ocp`, `istio-pr-perfscale`, `istio-periodic-perfscale`, `cr-servicemesh-aws`, `servicemesh-aws-fips` |
| `#team-ossm-release-maintenance` | `sync-upstream` (all release branches) |

## Performance Job Usage

The performance job (`istio-pr-perfscale`) is designed to measure service mesh performance in both ambient and sidecar modes. This job helps detect performance regressions between versions and provides baseline metrics for comparison.

### Job Configuration

The performance job has specific cluster and resource requirements:

```yaml
- always_run: false
  as: istio-pr-perfscale
  optional: true
  steps:
    cluster_profile: ossm-aws
    env:
      BASE_DOMAIN: servicemesh.devcluster.openshift.com
      COMPUTE_NODE_REPLICAS: "5"
      COMPUTE_NODE_TYPE: m6i.2xlarge
      CONTROL_PLANE_INSTANCE_TYPE: m6i.xlarge
      OPENSHIFT_INFRA_NODE_INSTANCE_TYPE: c6i.4xlarge
      SAIL_OPERATOR_CHANNEL: 1.30-nightly
      SET_ENV_BY_PLATFORM: custom
      ZONES_COUNT: "1"
    test:
    - chain: servicemesh-istio-perfscale
    workflow: openshift-qe-installer-aws
  timeout: 5h0m0s
```

### Test Chain Steps

The `servicemesh-istio-perfscale` chain performs the following tests:

1. **Ambient Mode Testing**:
   - Deploy control plane in ambient mode (`servicemesh-sail-operator-deploy-controlplane-ambient`)
   - Configure ambient environment (`openshift-qe-servicemesh-ambient-configure`)
   - Run ambient ingress performance tests (`openshift-qe-servicemesh-ambient-ingress-perf`)
   - Run ambient network performance tests (`openshift-qe-servicemesh-ambient-network-perf`)

2. **Sidecar Mode Testing**:
   - Undeploy ambient control plane (`servicemesh-sail-operator-undeploy-controlplane`)
   - Deploy control plane in sidecar mode (`servicemesh-sail-operator-deploy-controlplane-sidecar`)
   - Configure sidecar environment (`openshift-qe-servicemesh-sidecar-configure`)
   - Run sidecar ingress performance tests (`openshift-qe-servicemesh-sidecar-ingress-perf`)
   - Run sidecar network performance tests (`openshift-qe-servicemesh-sidecar-network-perf`)

### Manual Triggering

The Sail Operator performance job can only be triggered manually from a PR in the Sail Operator repository. This job is not configured to run automatically on any event.

**To trigger the job:**
1. Create or use an existing PR in [openshift-service-mesh/sail-operator](https://github.com/openshift-service-mesh/sail-operator)
2. Add a comment with the text: `/test ocp-4.22-istio-pr-perfscale`

**Important notes:**
- Job duration: ~4 hours (timeout: 5 hours)
- The job requires significant compute resources (5 m6i.2xlarge nodes)

### Accessing Test Results

#### Prow Job Artifacts
After job completion, navigate to the Prow run URL and access the `artifacts/istio-pr-perfscale/` directory.

Key directories:
- `ingress/` - Contains ingress performance test results
- `network/` - Contains network performance test results

#### Internal Performance Dashboard
**Note: Requires VPN access and Red Hat internal credentials**

- **Grafana Dashboard**: `http://ocp-intlab-grafana.rdu2.scalelab.redhat.com:3000/`
  - Credentials: `viewer/viewer` (read-only access)
  - Search for service mesh performance metrics by UUID

### Performance Metrics

**Ingress Performance**:
- `http_avg_rps` / `edge_avg_rps` - Average requests per second
- `http_avg_lat` / `edge_avg_lat` - Average latency in microseconds
- `http_avg_cpu_usage_ingress_gateway_pods` / `edge_avg_cpu_usage_ingress_gateway_pods` - CPU usage

**Network Performance** (`TCP_STREAM` / `TCP_RR` profiles):
- `throughput_{64,1024,8192}_{1,2,4}p` - TCP throughput by message size and parallelism
- `latency_{64,1024,8192}_1p` - Request-response latency by message size
