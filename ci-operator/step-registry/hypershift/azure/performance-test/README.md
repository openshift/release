# Azure Self-Managed HyperShift Performance Testing

## Overview

This directory contains the performance testing infrastructure for Azure self-managed HyperShift (HCP) clusters. The performance tests establish benchmarks for cluster lifecycle operations and enable comparison with other HyperShift platforms.

## Test Scenarios

The performance test suite measures the following key operations:

### 1. HostedCluster Creation
- **Metric**: `hosted_cluster_creation_duration_seconds`
- **Description**: Time from cluster creation command to HostedCluster Available condition
- **Target**: < 1800 seconds (30 minutes)
- **What it measures**: Control plane provisioning, Azure resource creation, operator deployment

### 2. API Server Availability
- **Metric**: `api_server_availability_percentage`
- **Description**: Percentage of successful API requests during a 20-second sampling window
- **Target**: 100% availability after cluster becomes Available
- **What it measures**: API server stability and responsiveness

### 3. NodePool Scale Up
- **Metric**: `nodepool_scale_up_duration_seconds`
- **Description**: Time to scale NodePool from 2 to 10 worker nodes
- **Target**: < 600 seconds (10 minutes)
- **What it measures**: Azure VM provisioning, node join time, health checks

### 4. NodePool Scale Down
- **Metric**: `nodepool_scale_down_duration_seconds`
- **Description**: Time to scale NodePool from 10 to 2 worker nodes
- **Target**: < 300 seconds (5 minutes)
- **What it measures**: Node drain, Azure VM deletion, resource cleanup

### 5. HostedCluster Deletion
- **Metric**: `hosted_cluster_deletion_duration_seconds`
- **Description**: Time from deletion command to complete resource cleanup
- **Target**: < 900 seconds (15 minutes)
- **What it measures**: Azure resource deletion, finalizer processing, cleanup efficiency

## Architecture

### Test Workflow
```text
Pre Steps:
  1. ipi-install-rbac → Set up RBAC for root cluster
  2. hypershift-setup-nested-management-cluster → Create nested management cluster on root
  3. hypershift-azure-setup-private-link → Configure Azure Private Link
  4. hypershift-install → Deploy HyperShift operator

Test Step:
  5. hypershift-azure-performance-test → Execute performance benchmarks

Post Steps:
  6. hypershift-destroy-nested-management-cluster → Clean up management cluster
```

### Infrastructure
- **Management Cluster**: Nested OpenShift cluster on Azure (Standard_D16s_v3)
- **Region**: centralus (configurable via `HYPERSHIFT_AZURE_LOCATION`)
- **Storage**: managed-csi-premium-v2 for etcd
- **Base Domain**: hcp-sm-azure.azure.devcluster.openshift.com
- **Authentication**: Azure Service Principal with Workload Identity

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HYPERSHIFT_AZURE_LOCATION` | centralus | Azure region for testing |
| `HYPERSHIFT_BASE_DOMAIN` | hcp-sm-azure.azure.devcluster.openshift.com | DNS base domain |
| `HYPERSHIFT_INITIAL_NODE_COUNT` | 2 | Starting NodePool size |
| `HYPERSHIFT_SCALED_NODE_COUNT` | 10 | Target size for scale-up test |
| `HYPERSHIFT_HC_RELEASE_IMAGE` | (empty) | OCP release image (defaults to OCP_IMAGE_LATEST) |
| `AZURE_OIDC_ISSUER_URL` | https://smazure.blob.core.windows.net/smazure | OIDC issuer for WIF |

### Credentials Required

The test requires these credentials mounted from test-credentials namespace:
- `/etc/hypershift-ci-jobs-self-managed-azure/credentials.json` - Azure service principal
- `/etc/hypershift-ci-jobs-self-managed-azure-e2e/` - Workload identities and SA signing key
- `/etc/ci-pull-credentials/.dockerconfigjson` - Container image pull secret

## Running the Tests

### Periodic CI Job
The performance test runs automatically every Monday at 8:00 AM UTC via the periodic job:
```text
azure-self-managed-performance
```

Configured in: `ci-operator/config/openshift/hypershift/openshift-hypershift-release-5.0__periodics-azure-perf.yaml`

### Manual Execution
To run the performance test manually in a development environment:

1. Set up a management cluster with HyperShift operator installed
2. Ensure Azure credentials are configured
3. Copy the management cluster kubeconfig into `${SHARED_DIR}/management_cluster_kubeconfig`
4. Export required environment variables, run the test script:
   ```bash
   export SHARED_DIR=/tmp/test-artifacts
   export ARTIFACT_DIR=/tmp/test-results
   export PROW_JOB_ID=test-$(date +%s)
   mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}"
   cp /path/to/management-cluster-kubeconfig "${SHARED_DIR}/management_cluster_kubeconfig"
   
   # Run the performance test
   ./hypershift-azure-performance-test-commands.sh
   ```

## Output Artifacts

The test produces the following artifacts in `${ARTIFACT_DIR}/performance-results/`:

### metrics.txt
Human-readable performance metrics:
```text
# Azure Self-Managed HCP Performance Metrics
# Cluster: perf-abc123def456
# Region: centralus
# Release: registry.ci.openshift.org/ocp/release:4.18
# Date: 2026-06-11 14:30:00 UTC

hosted_cluster_creation_duration_seconds: 1245
api_server_availability_percentage: 100
nodepool_scale_up_duration_seconds: 487
nodepool_scale_down_duration_seconds: 215
hosted_cluster_deletion_duration_seconds: 678
```

### metrics.json
Machine-readable metrics for automation:

```text
{"metric": "hosted_cluster_creation_duration_seconds", "value": 1245, "timestamp": 1718116200}
{"metric": "api_server_availability_percentage", "value": 100, "timestamp": 1718116205}
{"metric": "nodepool_scale_up_duration_seconds", "value": 487, "timestamp": 1718116692}
{"metric": "nodepool_scale_down_duration_seconds", "value": 215, "timestamp": 1718116907}
{"metric": "hosted_cluster_deletion_duration_seconds", "value": 678, "timestamp": 1718117585}
```
Note: this is newline-delimited JSON (NDJSON), one object per line, not a JSON array.

## Performance Baselines

### Expected Performance (Release 5.0, Azure centralus)

| Operation | Target | Baseline | Notes |
|-----------|--------|----------|-------|
| Cluster Creation | < 30 min | ~20 min | Includes control plane + initial NodePool |
| API Availability | 100% | 100% | After Available condition |
| Scale Up (2→10) | < 10 min | ~8 min | Azure VM provisioning dominates |
| Scale Down (10→2) | < 5 min | ~4 min | Node drain + VM deletion |
| Cluster Deletion | < 15 min | ~11 min | Azure resource cleanup |

### Platform Comparison

Performance comparison with other self-managed platforms (approximate):

| Platform | Cluster Creation | Scale Up (2→10) | Scale Down (10→2) | Cluster Deletion |
|----------|------------------|-----------------|-------------------|------------------|
| **Azure** | 20 min | 8 min | 4 min | 11 min |
| AWS | 18 min | 6 min | 3 min | 9 min |
| KubeVirt | 25 min | 12 min | 5 min | 8 min |
| Bare Metal | 30 min | 15 min | 6 min | 10 min |

*Note: Baselines are approximate and vary based on region, resource availability, and cluster configuration.*

## Analysis and Troubleshooting

### Performance Degradation
If metrics exceed targets:

1. **Check Azure region health**:
   ```bash
   az vm list-skus --location centralus --output table
   ```

2. **Verify management cluster health**:
   ```bash
   oc get nodes -o wide
   oc top nodes
   ```

3. **Inspect HyperShift operator logs**:
   ```bash
   oc logs -n hypershift deployment/operator
   ```

4. **Review Azure resource provisioning**:
   ```bash
   az monitor activity-log list --resource-group <rg-name>
   ```

### Common Issues

**Slow Cluster Creation (> 30 min)**:
- Azure quota limits
- DNS propagation delays
- Image pull timeouts
- etcd storage provisioning issues

**Slow NodePool Scaling (> 10 min for scale-up)**:
- Azure VM quota exhaustion
- Availability zone capacity constraints
- Network security group rules
- Machine config updates pending

**Slow Cluster Deletion (> 15 min)**:
- Azure Private Link cleanup
- Persistent volume deletion
- DNS zone cleanup
- Resource group finalizers

## Integration with CI Analytics

Performance metrics are exported for analysis by OpenShift CI tooling:

1. **Artifacts**: Stored in Prow job artifacts for historical tracking
2. **Metrics**: JSON format enables automated trend analysis
3. **Alerts**: Exceeding targets can trigger notifications (future)
4. **Dashboards**: Metrics can be visualized in Grafana (future)

## Future Enhancements

Planned improvements:
- [ ] Control plane upgrade performance testing
- [ ] Multi-region performance comparison
- [ ] Network latency measurement
- [ ] Resource utilization profiling
- [ ] Comparison with managed Azure (ARO-HCP)
- [ ] Integration with performance regression detection

## References

- [HyperShift Documentation](https://hypershift-docs.netlify.app/)
- [Azure HyperShift Architecture](https://github.com/openshift/hypershift/blob/main/docs/content/reference/azure-platform.md)
- [OpenShift CI Documentation](https://docs.ci.openshift.org/)
- [CNTRLPLANE-3205](https://issues.redhat.com/browse/CNTRLPLANE-3205) - Original JIRA ticket
