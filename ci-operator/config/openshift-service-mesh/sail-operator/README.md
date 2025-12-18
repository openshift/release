# OpenShift Service Mesh CI Documentation

Maintenance documentation for OpenShift Service Mesh CI jobs. Contains essential information not available in the configuration files themselves. Please add here any information that may help future maintainers.

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
      SAIL_OPERATOR_CHANNEL: 1.28-nightly
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
2. Add a comment with the text: `/test ocp-4.20-istio-pr-perfscale`

Example PR: [openshift-service-mesh/sail-operator #633](https://github.com/openshift-service-mesh/sail-operator/pull/633)

**Important notes:**
- Job duration: ~4 hours (timeout: 5 hours)
- The job requires significant compute resources (5 m6i.2xlarge nodes)
- Performance configuration may need manual updates depending on testing requirements

### Accessing Test Results

Performance test results are available in multiple formats and locations:

#### 1. Prow Job Artifacts
After job completion, navigate to the Prow run URL and access artifacts:
```
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/<job-id>/artifacts/istio-pr-perfscale/
```

Key directories:
- `ingress/` - Contains ingress performance test results
- `network/` - Contains network performance test results

#### 2. Build Logs
Raw performance data is available in build logs. Look for lines containing performance metrics:
```
time="2025-12-05 18:10:01" level=info msg="http: Rps=5001 avgLatency=2ms P95Latency=2ms" file="exec.go:149"
```

#### 3. Internal Performance Dashboard
**Note: Requires VPN access and Red Hat internal credentials**

- **Grafana Dashboard**: `http://ocp-intlab-grafana.rdu2.scalelab.redhat.com:3000/`
  - Credentials: `viewer/viewer` (read-only access)
  - Search for service mesh performance metrics by UUID

#### 4. Performance Analysis Bot (Future)
An internal Slack bot for automated performance regression detection is planned:
```
@PerfScale Jedi analyze pr: https://github.com/openshift-service-mesh/sail-operator/pull/XXX, compare with 4.21
```

**Current status**: In development, expected implementation timeline depends on team capacity.

### Performance Metrics

The performance tests measure:

**Ingress Performance**:
- `http_avg_rps` / `edge_avg_rps` - Average requests per second for HTTP and edge termination
- `http_avg_lat` / `edge_avg_lat` - Average latency in microseconds (at 5000 request rate)
- `http_avg_cpu_usage_ingress_gateway_pods` / `edge_avg_cpu_usage_ingress_gateway_pods` - CPU usage of ingress gateway pods

**Network Performance**:
- **Throughput metrics** (`TCP_STREAM` profile):
  - `throughput_64_1p/2p/4p` - TCP throughput with 64-byte messages (1, 2, 4 parallel connections)
  - `throughput_1024_1p/2p/4p` - TCP throughput with 1KB messages (1, 2, 4 parallel connections)
  - `throughput_8192_1p/2p/4p` - TCP throughput with 8KB messages (1, 2, 4 parallel connections)
- **Latency metrics** (`TCP_RR` profile):
  - `latency_64_1p` - Request-response latency with 64-byte messages
  - `latency_1024_1p` - Request-response latency with 1KB messages
  - `latency_8192_1p` - Request-response latency with 8KB messages

**Test Configuration**:
Each test run generates a UUID that can be used to correlate results across different systems and dashboards.

### Use Cases

This job is primarily used for:
1. **Version Bump Testing**: Detect regressions when updating service mesh versions
2. **Performance Baseline**: Establish performance baselines for new releases
3. **Comparative Analysis**: Compare OpenShift service mesh performance with upstream benchmarks
4. **Resource Planning**: Understand resource requirements for different deployment modes

### Troubleshooting

**Common Issues**:
- Job timeout: Consider increasing timeout if tests consistently run close to 5 hours
- Resource allocation: Verify AWS cluster has sufficient capacity for requested instance types
- Results access: Ensure VPN connection and proper credentials for internal dashboards

**Getting Help**:
- Performance-related questions: Contact the PerfScale team via internal Slack channels
- Job configuration issues: Contact the OpenShift Service Mesh team