# AWS Nested Virtualization E2E Test

This step-registry component provides end-to-end testing for AWS clusters with nested virtualization enabled via
install-config.yaml.

## Overview

Nested virtualization allows virtual machines to run inside EC2 instances, which is required for workloads like
OpenShift Virtualization (CNV). This test workflow:

1. **Configures** install-config.yaml to enable nested virtualization via cpuOptions
2. **Provisions** an AWS IPI cluster with nested virtualization enabled from the start
3. **Validates** that nested virtualization is properly configured with comprehensive checks

This workflow uses the **install-config.yaml approach**, setting
`compute[*].platform.aws.cpuOptions.nestedVirtualization=Enabled` during cluster provisioning. This is the recommended
production deployment method.

## Components

### Workflow: `openshift-e2e-aws-nested-virtualization`

**File:** `openshift-e2e-aws-nested-virtualization-workflow.yaml`

The main workflow that orchestrates the entire test. It uses:

- `ipi-conf-aws` chain for AWS configuration
- `ipi-conf-aws-nested-virtualization` step to modify install-config.yaml
- `ipi-install` chain for cluster installation
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

### Environment Variables

| Variable                | Default    | Description                                                           |
|-------------------------|------------|-----------------------------------------------------------------------|
| `COMPUTE_NODE_TYPE`     | (required) | EC2 instance type for compute nodes (e.g., m8i.2xlarge)               |
| `COMPUTE_NODE_REPLICAS` | `"3"`      | Number of worker nodes. NestedVirt is only supported on Compute Nodes |

## Example Test Configuration

The test `aws-ipi-nested-virtualization-f14` has been added to:

- **Config:**
  `ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installation-nightly-5.0.yaml`
- **Config:**
  `ci-operator/config/openshift/verification-tests/openshift-verification-tests-main__installation-nightly-5.1.yaml`
- **Job:** `ci-operator/jobs/openshift/verification-tests/openshift-verification-tests-main-periodics.yaml`

## How It Works

### Step 1: AWS IPI Configuration

Uses standard `ipi-conf-aws` chain to configure AWS cluster parameters (regions, instance types, etc.).

### Step 2: Install-Config Modification

The `ipi-conf-aws-nested-virtualization` step modifies the install-config.yaml to add:

```yaml
compute:
- platform:
    aws:
      cpuOptions:
        nestedVirtualization: Enabled
```

### Step 3: Cluster Provisioning

Standard IPI installation (`ipi-install` chain) provisions the cluster. EC2 instances are created with nested
virtualization enabled from the start.

### Step 4: Validation

The validation step runs all checks against each compute node and reports:

- Individual check results (PASS/FAIL)
- Overall validation summary
- Exit code 0 if all checks pass, 1 if any fail

### Step 5: Cleanup

Standard `ipi-aws-post` chain tears down the cluster and resources.

## Troubleshooting

### Instance Capacity Issues

If AWS reports `InsufficientInstanceCapacity` for m8i instances:

- Try a different region
- Use a smaller instance size (e.g., m8i.xlarge instead of m8i.2xlarge)
- Use c8i or r8i family instead

### Validation Failures

**Check 1 Fails (AWS CpuOptions):**

- The install-config.yaml modification may not have been applied
- Check the `ipi-conf-aws-nested-virtualization` step logs
- Verify `COMPUTE_NODE_TYPE` is set to a supported instance type

**Check 2 Fails (CPU flags):**

- Wrong instance type (not c8i/m8i/r8i)
- Verify `COMPUTE_NODE_TYPE` is set correctly

**Check 3 Fails (KVM module):**

- OS issue or kernel doesn't support KVM
- Check node kernel version and RHCOS image

## Related Components

- **ipi-conf-aws-nested-virtualization:** The step that modifies install-config.yaml to enable nested virtualization
- **ipi-aws workflow:** Standard AWS IPI cluster provisioning
- **cnv-e2e-ipi-aws workflow:** Similar workflow for full CNV testing

## References

- [AWS Nested Virtualization Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html)
- [OpenShift Virtualization](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [Step Registry Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/)
