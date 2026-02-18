# NVIDIA DRA (Dynamic Resource Allocation) Testing

This directory contains CI step-registry configuration for testing NVIDIA DRA functionality on OpenShift GPU-enabled clusters.

## Overview

NVIDIA DRA testing validates the Kubernetes Dynamic Resource Allocation (DRA) API with NVIDIA GPUs:
- Single GPU allocation to pods via ResourceClaims
- Resource claim lifecycle management (pod deletion, cleanup)
- Device accessibility and CDI integration

## Directory Structure

```
nvidia-dra/
├── nfd-install/                         # NFD Operator installation via OLM
│   ├── openshift-e2e-nvidia-dra-nfd-install-ref.yaml
│   ├── openshift-e2e-nvidia-dra-nfd-install-commands.sh
│   └── OWNERS
├── gpu-operator-install/                # GPU Operator installation via OLM
│   ├── openshift-e2e-nvidia-dra-gpu-operator-install-ref.yaml
│   ├── openshift-e2e-nvidia-dra-gpu-operator-install-commands.sh
│   └── OWNERS
├── test/                                # Test execution step
│   ├── openshift-e2e-nvidia-dra-test-ref.yaml
│   ├── openshift-e2e-nvidia-dra-test-commands.sh
│   └── OWNERS
├── cleanup/                             # Cleanup step
│   ├── openshift-e2e-nvidia-dra-cleanup-ref.yaml
│   ├── openshift-e2e-nvidia-dra-cleanup-commands.sh
│   └── OWNERS
├── openshift-e2e-nvidia-dra-workflow.yaml       # Workflow for AWS GPU testing
├── OWNERS
└── README.md
```

## Workflow

### NVIDIA DRA Workflow (`openshift-e2e-nvidia-dra`)

Provisions an AWS cluster with GPU worker nodes and tests NVIDIA DRA functionality.

**Workflow Steps:**
1. **Pre**: Provision AWS IPI cluster with GPU nodes → Install NFD Operator via OLM → Install GPU Operator via OLM (with CDI enabled)
2. **Test**: Install DRA Driver (via Helm) → Run basic DRA extended tests
3. **Post**: Cleanup DRA Driver and test resources → Destroy cluster

**Supported GPU Instance Types:**
- `g4dn.xlarge` - Basic testing (1x Tesla T4, Turing) - **$0.526/hr** (default)
- `g4dn.12xlarge` - Multi-GPU (4x Tesla T4, Turing) - $3.912/hr
- `g5.xlarge` - Advanced (1x A10G, Ampere) - $1.006/hr
- `g5.12xlarge` - Multi-GPU (4x A10G, Ampere) - $5.672/hr
- `p4d.24xlarge` - MIG testing (8x A100, Ampere) - $32.77/hr
- `p5.48xlarge` - H100 testing (8x H100, Hopper) - $98.32/hr

**Example Job Config:**
```yaml
tests:
- as: e2e-aws-nvidia-dra-basic
  optional: true
  run_if_changed: ^test/extended/(node/dra/nvidia|dra/nvidia)/.*
  steps:
    cluster_profile: aws
    workflow: openshift-e2e-nvidia-dra
    env:
      COMPUTE_NODE_TYPE: g4dn.xlarge
      COMPUTE_NODE_REPLICAS: "1"
      DRA_TEST_SUITE: basic
      GPU_TYPE: tesla-t4
      GPU_ARCHITECTURE: turing
      GPU_MIG_CAPABLE: "false"
```

## Test Suite

The `DRA_TEST_SUITE` environment variable is set to **`basic`** (default) which runs:

- Single GPU allocation to pod via ResourceClaim
- Pod deletion and resource cleanup validation
- ~8-10 minutes runtime

**Tests executed:**
- `[sig-scheduling] NVIDIA DRA Basic GPU Allocation should allocate single GPU to pod via DRA`
- `[sig-scheduling] NVIDIA DRA Basic GPU Allocation should handle pod deletion and resource cleanup`

## Environment Variables

### Cluster Configuration
- `COMPUTE_NODE_TYPE` - GPU instance type for worker nodes (default: g4dn.xlarge)
- `COMPUTE_NODE_REPLICAS` - Number of GPU worker nodes (default: 1)

### Test Configuration
- `DRA_TEST_SUITE` - Test suite to run (basic, multi-gpu, partitionable, all)
- `GPU_TYPE` - GPU hardware type (tesla-t4, a10g, a100, l4)
- `GPU_ARCHITECTURE` - NVIDIA architecture (turing, ampere, hopper)
- `GPU_MIG_CAPABLE` - MIG support (true/false)
- `DRA_SKIP_PREREQUISITES` - Skip GPU Operator installation (default: false)

## Cost

**AWS g4dn.xlarge (1x Tesla T4) - Default:**
- Instance cost: ~$0.53/hour
- Test duration: ~60-75 minutes (includes cluster provisioning)
- **Cost per run**: ~$0.60-$0.70

This configuration provides cost-effective basic DRA validation suitable for PR testing and periodic jobs.

**Future GPU types:**
- `p4d.24xlarge` (A100): For MIG and advanced DRA partitioning tests
- `p5.48xlarge` (H100): For next-gen Hopper architecture and advanced features

## Test Behavior

- **No GPU Nodes**: Tests skip automatically with message "No GPU nodes available in the cluster"
- **Prerequisites**:
  - GPU Operator is installed via OLM in the workflow's `pre` phase (with CDI enabled)
  - DRA Driver is installed via Helm during test execution if not already present
  - Both installations are idempotent and skip if already installed

## Prerequisites

The workflow automatically installs:
- **Node Feature Discovery (NFD) Operator** (via OLM from redhat operators catalog)
  - Installed in the `pre` phase first to label GPU nodes
  - Creates NodeFeatureDiscovery CR instance
  - Ensures nodes are labeled with `nvidia.com/gpu.present=true` before GPU operator installation
- **NVIDIA GPU Operator** (via OLM from certified operators catalog)
  - Installed in the `pre` phase after NFD installation
  - ClusterPolicy configured with `cdi.enabled=true` (REQUIRED for DRA)
  - Depends on NFD for proper GPU node labeling
- **NVIDIA DRA Driver** (via Helm, installed by test step)
  - Installed automatically during test execution if not present
  - Latest version from nvidia.github.io/gpu-operator Helm repository
  - Required SCC permissions are automatically granted

All prerequisites are idempotent - they skip installation if already present (detected via running pods and existing resources).

## Cleanup

The cleanup step removes:
- NVIDIA DRA Driver Helm release
- NVIDIA GPU Operator Helm release
- Node Feature Discovery Operator (subscription and CR)
- Associated namespaces (nvidia-dra-driver-gpu, nvidia-gpu-operator, openshift-nfd)
- ClusterRoleBindings for SCC permissions
- Test resources (DeviceClasses, ResourceClaims, test namespaces)

Cleanup is `optional_on_success`, meaning it runs on failure but can be skipped on success for debugging.

## Usage

This workflow is used by the `e2e-aws-nvidia-dra-basic` job in the `openshift/origin` repository to validate NVIDIA DRA functionality on pull requests that modify DRA test code. The job can also be configured as a periodic job for ongoing validation of DRA functionality on NVIDIA GPUs.

## References

- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/)
- [NVIDIA DRA Driver Documentation](https://github.com/NVIDIA/k8s-dra-driver)
- [Kubernetes DRA Documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [OpenShift Extended Tests](https://github.com/openshift/origin/tree/master/test/extended)
