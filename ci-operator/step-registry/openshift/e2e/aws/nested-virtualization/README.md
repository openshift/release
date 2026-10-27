# AWS Nested Virtualization E2E Test

This step-registry component provides end-to-end testing for AWS clusters with nested virtualization enabled on compute nodes.

## Overview

Nested virtualization allows virtual machines to run inside EC2 instances, which is required for workloads like OpenShift Virtualization (CNV). This test workflow:

1. **Provisions** an AWS IPI cluster with instance types that support nested virtualization (m8i.2xlarge by default)
2. **Enables** nested virtualization by modifying AWS EC2 CpuOptions on each compute node
3. **Validates** that nested virtualization is properly configured with several comprehensive checks

## Components

### Workflow: `openshift-e2e-aws-nested-virtualization`

**File:** `openshift-e2e-aws-nested-virtualization-workflow.yaml`

The main workflow that orchestrates the entire test. It uses:
- `ipi-aws-pre` chain for cluster provisioning
- `cnv-enable-nested-virtualization-aws` step to enable nested virt
- `openshift-e2e-aws-nested-virtualization` step for validation
- `ipi-aws-post` chain for cleanup

### Validation Step: `openshift-e2e-aws-nested-virtualization`

**Files:**
- `openshift-e2e-aws-nested-virtualization-ref.yaml` - Step definition
- `openshift-e2e-aws-nested-virtualization-commands.sh` - Validation script

Performs several validation checks on each compute node:

1. **AWS CpuOptions Check**
   - Queries AWS EC2 API to verify `CpuOptions.NestedVirtualization` is set to `enabled`

2. **CPU Virtualization Flags**
   - Checks `/proc/cpuinfo` for Intel VT-x (vmx) or AMD-V (svm) flags

3. **KVM Module**
   - Verifies KVM kernel module is loaded
   - Confirms `/dev/kvm` device exists

## Usage

### In a CI Configuration

Add to your `ci-operator/config/<org>/<repo>/<file>.yaml`:

```yaml
tests:
- as: aws-nested-virt-e2e
  steps:
    cluster_profile: aws-qe
    env:
      BASE_DOMAIN: qe.devcluster.openshift.com
      COMPUTE_NODE_TYPE: m8i.2xlarge  # or c8i.*, r8i.*
      COMPUTE_NODE_REPLICAS: "3"
    workflow: openshift-e2e-aws-nested-virtualization
```

### Supported Instance Types

Only certain AWS EC2 instance families support nested virtualization:
- **c8i** - Compute optimized (Intel 8th gen)
- **m8i** - General purpose (Intel 8th gen)
- **r8i** - Memory optimized (Intel 8th gen)

Bare-metal instances (*.metal) have native KVM support and don't require the enablement step.

### Environment Variables

| Variable                | Default    | Description                                                   |
|-------------------------|------------|---------------------------------------------------------------|
| `COMPUTE_NODE_TYPE`     | (required) | EC2 instance type for compute nodes (e.g., m8i.2xlarge)       |
| `COMPUTE_NODE_REPLICAS` | `"3"`      | Number of worker nodes. Set to `"0"` for compact/SNO clusters |

## Example Test Configuration

The test `aws-ipi-nested-virtualization-f14` has been added to:
- **Config:** `ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installation-nightly-5.0.yaml`
- **Config:** `ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installation-nightly-5.1.yaml`
- **Job:** `ci-operator/jobs/openshift/verification-tests/openshift-verification-tests-main-periodics.yaml`

## How It Works

### Step 1: Cluster Provisioning

Uses standard `ipi-aws-pre` chain to create a cluster with the specified instance types.

### Step 2: Enable Nested Virtualization

The `cnv-enable-nested-virtualization-aws` step:
1. Identifies all compute nodes (or control plane nodes for compact/SNO)
2. For each node:
   - Cordons the node
   - Drains workloads
   - Stops the EC2 instance
   - Modifies `CpuOptions` to enable nested virtualization
   - Starts the EC2 instance
   - Waits for node to become Ready
   - Uncordons the node

### Step 3: Validation

The validation step runs all checks against each compute node and reports:
- Individual check results (PASS/FAIL)
- Overall validation summary
- Exit code 0 if all checks pass, 1 if any fail

### Step 4: Cleanup

Standard `ipi-aws-post` chain tears down the cluster and resources.

## Troubleshooting

### Instance Capacity Issues

If AWS reports `InsufficientInstanceCapacity` for m8i instances:
- Try a different region
- Use a smaller instance size (e.g., m8i.xlarge instead of m8i.2xlarge)
- Use c8i or r8i family instead

### Validation Failures

**Check 1 Fails (AWS CpuOptions):**
- The enablement step may have failed
- Check the `cnv-enable-nested-virtualization-aws` step logs

**Check 2 Fails (CPU flags):**
- Wrong instance type (not c8i/m8i/r8i)
- Verify `COMPUTE_NODE_TYPE` is set correctly

**Check 3 Fails (KVM module):**
- OS issue or kernel doesn't support KVM
- Check node kernel version and RHCOS image

## Related Components

- **cnv-enable-nested-virtualization-aws:** The step that actually enables nested virt (reused from CNV team)
- **ipi-aws workflow:** Standard AWS IPI cluster provisioning
- **cnv-e2e-ipi-aws workflow:** Similar workflow for full CNV testing

## References

- [AWS Nested Virtualization Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
- [OpenShift Virtualization](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [Step Registry Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/)
