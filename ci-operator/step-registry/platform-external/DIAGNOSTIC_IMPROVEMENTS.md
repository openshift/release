# Platform-External Diagnostic Collection Improvements

## Overview

This document describes the diagnostic collection improvements made to the platform-external workflow to better debug installation failures, particularly for bootstrap and control plane issues.

## Problem Statement

The platform-external workflow was experiencing failures with minimal diagnostic information:
1. **No bootstrap logs collected** when installation fails
2. **No EC2 console logs** to debug instance boot/ignition failures
3. **No load balancer health diagnostics** to identify API connectivity issues
4. **Limited control plane diagnostics** when waiting for masters times out
5. **No AWS infrastructure state** captured on failure

## Solution Overview

Implemented comprehensive diagnostic collection through two main improvements:

### 1. New Post-Gather Step: `platform-external-post-gather-aws`

**Location**: `ci-operator/step-registry/platform-external/post/gather-aws/`

**Purpose**: Collect AWS-specific diagnostics on failure only (best-effort, optional on success)

**Capabilities**:

#### A. Bootstrap Logs Collection
- Uses `openshift-install gather bootstrap` to collect comprehensive bootstrap logs
- Requires: `BOOTSTRAP_IP` in SHARED_DIR, SSH private key in CLUSTER_PROFILE_DIR
- Output: `log-bundle-*.tar.gz` in ARTIFACT_DIR
- Contains: journal logs, service status, container logs from bootstrap node

#### B. EC2 Instance Console Logs
- Extracts instance IDs from CloudFormation stacks
- Queries EC2 API for all cluster instances by tag
- Collects console output for each instance (bootstrap, masters, workers)
- Output: `ec2-console-logs/<instance-id>-<name>.log`
- Use cases: Boot failures, kernel panics, ignition errors, systemd failures

#### C. Load Balancer Diagnostics
- Discovers all ELBv2 load balancers for the cluster
- Lists all target groups (API, service endpoints)
- Collects target health status for each target
- Output: `load-balancer-diagnostics/target-health-*.json`
- Shows: Which targets are healthy/unhealthy, health check failures, reasons

#### D. CloudFormation Stack Events
- Collects events for all cluster-related stacks
- Shows resource creation timeline
- Identifies provisioning failures
- Output: `cloudformation-events/<stack-name>-events.json`

#### E. Instance Metadata
- Collects EC2 instance details for all cluster instances
- Includes: state, type, security groups, network interfaces, tags
- Output: `ec2-console-logs/<instance-id>-metadata.json`

#### F. Summary Report
- Human-readable summary of all collected diagnostics
- Shows: region, infra ID, bootstrap status, instance count, LB status
- Output: `aws-diagnostics-summary.txt`

**Configuration**:
- `timeout: 20m` - allows time for bootstrap log gathering over SSH
- `grace_period: 10m` - extra time for cleanup
- `best_effort: true` - continues even if some operations fail
- `optional_on_success: true` - **only runs on failure** to protect sensitive data

### 2. Enhanced Control Plane Wait Step

**Location**: `ci-operator/step-registry/platform-external/cluster/wait-for/ready/control/`

**Improvements**:

#### A. Configurable Timeout
- Environment variable: `CONTROL_PLANE_WAIT_MAX_ITERATIONS` (default: 60)
- Total wait time: 60 iterations × 30 seconds = 30 minutes
- Progress tracking with iteration counter

#### B. Periodic Diagnostic Collection
- Collects diagnostics every 5 iterations (2.5 minutes)
- Snapshot includes:
  - Node status and details
  - Pod status in critical namespaces (kube-system, apiserver, etcd)
  - Recent events
  - Machine API resources
  - Cluster operator status
- Output: `control-plane-diagnostics/iteration-NNN/`

#### C. Progress Indicators
- Shows master ready count every iteration
- Detailed status every 5 minutes
- Displays pod status in kube-system

#### D. Comprehensive Final Diagnostics on Timeout
- Full cluster state capture
- Detailed pod information across all critical namespaces
- Complete event history
- Cluster operators and version info
- Machine API state
- Summary report with timeline
- Output: `control-plane-final-state/`

## Integration

### Workflow Changes

**Updated**: `platform-external-cluster-aws-post-chain.yaml`
```yaml
chain:
  as: platform-external-cluster-aws-post
  steps:
  - ref: platform-external-post-gather-aws  # NEW - runs first, on failure only
  - ref: platform-external-cluster-aws-destroy
```

The new gather step runs **before** destroy, ensuring diagnostics are collected even if destroy fails.

### Files Created

```
platform-external/
├── post/
│   └── gather-aws/
│       ├── platform-external-post-gather-aws-commands.sh  (NEW)
│       ├── platform-external-post-gather-aws-ref.yaml     (NEW)
│       └── OWNERS                                          (NEW)
└── cluster/
    └── wait-for/
        └── ready/
            └── control/
                ├── platform-external-cluster-wait-for-ready-control-commands.sh  (ENHANCED)
                └── platform-external-cluster-wait-for-ready-control-ref.yaml      (ENHANCED)
```

### Files Modified

1. `platform-external-cluster-aws-post-chain.yaml` - Added gather-aws step
2. `platform-external-cluster-wait-for-ready-control-commands.sh` - Enhanced diagnostics
3. `platform-external-cluster-wait-for-ready-control-ref.yaml` - Added configuration

## Usage Examples

### Successful Run (No Extra Diagnostics)
```
1. Installation proceeds normally
2. Control plane nodes become ready (periodic snapshots collected)
3. Installation completes
4. platform-external-post-gather-aws SKIPPED (optional_on_success: true)
5. Infrastructure destroyed
```

### Failed Run (Full Diagnostics)
```
1. Installation starts
2. Control plane wait begins
3. Periodic diagnostics collected every 2.5 minutes
4. Timeout after 30 minutes
5. Final control plane diagnostics collected
6. platform-external-post-gather-aws runs:
   - Connects to bootstrap via SSH
   - Collects log-bundle-*.tar.gz
   - Queries CloudFormation for instance IDs
   - Downloads console logs for all instances
   - Checks load balancer target health
   - Gathers CloudFormation events
   - Creates summary report
7. Infrastructure destroyed
```

### Artifacts on Failure
```
artifacts/
├── log-bundle-20260407-120000.tar.gz           # Bootstrap logs
├── bootstrap-gather.log                         # Gather operation log
├── aws-diagnostics-summary.txt                  # Summary report
├── aws-instance-ids.txt                         # All instance IDs
├── ec2-console-logs/
│   ├── i-0abc123-bootstrap.log
│   ├── i-0abc123-bootstrap-metadata.json
│   ├── i-0def456-master-0.log
│   ├── i-0def456-master-0-metadata.json
│   └── ...
├── load-balancer-diagnostics/
│   ├── load-balancers.json
│   ├── target-groups.json
│   ├── target-health-api-ext.json
│   ├── target-health-api-ext.txt
│   └── ...
├── cloudformation-events/
│   ├── infra-bootstrap-events.json
│   ├── infra-bootstrap-events.txt
│   └── ...
├── control-plane-diagnostics/
│   ├── iteration-005/
│   ├── iteration-010/
│   └── ...
└── control-plane-final-state/
    ├── summary.txt
    ├── nodes.yaml
    ├── pods-all.txt
    ├── namespace-kube-system/
    └── ...
```

## Debugging Workflows

### Scenario 1: Bootstrap Failure
**Symptoms**: Installation hangs during bootstrap, API never becomes available

**Diagnostics to Check**:
1. `log-bundle-*.tar.gz` - Complete bootstrap logs
   - Extract: `tar -xzf log-bundle-*.tar.gz`
   - Check: `bootstrap/journals/bootkube.service.log`
   - Check: `bootstrap/containers/`
2. `ec2-console-logs/i-*-bootstrap.log` - Boot process, ignition
   - Look for: ignition errors, failed systemd units, kernel panics
3. `load-balancer-diagnostics/target-health-api-ext.json`
   - Check if bootstrap registered as target
   - Check health check failures

### Scenario 2: Master Nodes Not Booting
**Symptoms**: Masters stuck in Pending or never appear

**Diagnostics to Check**:
1. `ec2-console-logs/i-*-master-*.log` - Boot logs
   - Look for: ignition failures, disk issues, network problems
2. `ec2-console-logs/i-*-master-*-metadata.json` - Instance state
   - Check: instance state, security groups, network interfaces
3. `cloudformation-events/*-master-events.json` - Provisioning
   - Look for: CloudFormation resource failures
4. `control-plane-final-state/machines.yaml` - Machine API
   - Check: machine provisioning status, errors

### Scenario 3: API Not Healthy
**Symptoms**: Masters boot but API health checks fail

**Diagnostics to Check**:
1. `load-balancer-diagnostics/target-health-api-*.json`
   - Check target states: healthy, unhealthy, initial, draining
   - Check reasons: connection refused, timeout, unhealthy threshold
2. `control-plane-final-state/namespace-openshift-kube-apiserver/`
   - Check apiserver pod status
   - Check pod logs for startup errors
3. `log-bundle-*/master-*/journals/kubelet.service.log`
   - Check kubelet connecting to API

### Scenario 4: Etcd Issues
**Symptoms**: Control plane partially ready, etcd problems

**Diagnostics to Check**:
1. `control-plane-final-state/namespace-openshift-etcd/`
   - Check etcd pod status
   - Check events for etcd errors
2. `log-bundle-*/master-*/containers/etcd-*`
   - Etcd logs from bootstrap perspective
3. `control-plane-diagnostics/iteration-NNN/events-recent.txt`
   - Timeline of etcd-related events

## Testing Strategy

### Unit Testing
- [x] Script syntax validation: `bash -n *.sh`
- [ ] Test with missing BOOTSTRAP_IP (should gracefully skip)
- [ ] Test with missing metadata.json (should use LEASED_RESOURCE)
- [ ] Test with no CloudFormation stacks (should handle gracefully)

### Integration Testing
- [ ] Run on successful installation (should skip gather-aws)
- [ ] Run on bootstrap failure (should collect all diagnostics)
- [ ] Run on control plane timeout (should collect control plane diagnostics)
- [ ] Run on network failure (should collect partial diagnostics)

### Verification Checklist
- [ ] Bootstrap logs collected in log-bundle-*.tar.gz
- [ ] Console logs for all instances present
- [ ] Load balancer health status captured
- [ ] CloudFormation events collected
- [ ] Summary report generated
- [ ] Control plane diagnostics collected periodically
- [ ] Final state captured on timeout
- [ ] Step completes successfully even with partial failures
- [ ] Step skipped on successful runs

## Performance Considerations

### Resource Usage
- **CPU**: 100m (lightweight, mostly API calls)
- **Memory**: 300Mi (sufficient for log downloads)
- **Timeout**: 20 minutes (allows SSH bootstrap gather)
- **Network**: Moderate (downloads console logs, ~1-5MB per instance)

### Time Impact
- **Success case**: 0 seconds (step skipped)
- **Failure case**: 5-15 minutes depending on:
  - Bootstrap SSH connectivity (5-10 min)
  - Number of instances (1-3 min)
  - Network latency (varies)

### Cost Impact
- **AWS API calls**: ~50-100 calls per failure (negligible cost)
- **Data transfer**: Minimal (console logs, CloudFormation events)
- **Storage**: 50-200MB in artifacts (typical failure)

## Security Considerations

### Sensitive Data Protection
1. **Only runs on failure**: `optional_on_success: true` prevents collection from successful runs
2. **No credentials in logs**: Bootstrap logs may contain token references but not values
3. **No kubeconfig exposure**: Kubeconfig handled internally, not exposed
4. **Instance metadata**: Public data only (IDs, states, not credentials)

### Access Control
- Requires AWS credentials (provided by CI infrastructure)
- Requires SSH key (provided by cluster profile)
- All artifacts stored in CI-controlled artifact bucket

## Future Enhancements

### Potential Improvements
1. **Automated analysis**: Parse bootstrap logs for common failure patterns
2. **Smart filtering**: Only collect console logs for failed instances
3. **Compression**: Compress console logs before upload
4. **Parallel collection**: Gather bootstrap and console logs concurrently
5. **Platform abstraction**: Extend to Azure, GCP with similar diagnostics
6. **Metric collection**: CloudWatch metrics for instances and load balancers

### Additional Diagnostics
1. **VPC flow logs**: Network traffic analysis
2. **Route53 health checks**: DNS resolution verification
3. **Security group analysis**: Firewall rule validation
4. **S3 bucket logs**: Ignition download verification
5. **CloudTrail events**: API call history

## References

### Existing Patterns
- `openstack/gather/openstack-gather-commands.sh` - Platform-specific gathering
- `gather/aws-console/gather-aws-console-commands.sh` - Console log collection
- `platform-external/cluster/wait-for/ccm-nodes-initialized/` - Wait with diagnostics

### Documentation
- [OpenShift Install Gather Bootstrap](https://docs.openshift.com/container-platform/4.13/installing/installing-troubleshooting.html#installation-bootstrap-gather_installing-troubleshooting)
- [AWS EC2 Console Output](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-console.html)
- [ELBv2 Target Health](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)

## Maintenance

### Ownership
- **Team**: Platform External / UPI
- **Reviewers**: See `OWNERS` files in each directory
- **Contact**: #forum-platform-external

### Update Process
1. Test changes in rehearsal jobs
2. Update documentation (this file)
3. Get review from OWNERS
4. Merge to release repository
5. Monitor periodic jobs for regressions

---

**Last Updated**: 2026-04-07
**Author**: Claude Code + mtulio
**Status**: Implemented, pending testing
