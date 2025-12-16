# AGENTS.md - Guide for AI Coding Agents

This file provides guidance for AI agents (like Claude Code) when working with redhat-chaos Prow CI configurations. It complements the human-focused documentation with agent-specific instructions and patterns.

## File Location
This file is located at: `ci-operator/config/redhat-chaos/prow-scripts/AGENTS.md`
Prow CI configuration files are located in `ci-operator/config/redhat-chaos/prow-scripts`

## Folder Structure Overview
```
redhat-chaos/
├── prow-scripts/                   # Main chaos testing configurations
│   ├── AGENTS.md                   # This file - AI agent guidance
│   ├── OWNERS                      # Reviewers and approvers
│   ├── agents/                     # Claude Code subagent definitions
│   │   └── create_chaos_jobs.md
│   ├── scripts/                    # Helper scripts for automation
│   │   ├── get_prior_minor_version.sh
│   │   ├── create_chaos_jobs.sh
│   │   └── create_upgrade_chaos_jobs.sh
│   ├── redhat-chaos-prow-scripts-main__<VERSION>-nightly.yaml
│   ├── redhat-chaos-prow-scripts-main__<VERSION>-nightly-upgrade.yaml
│   ├── redhat-chaos-prow-scripts-main__rosa-<VERSION>-nightly.yaml
│   ├── redhat-chaos-prow-scripts-main__cr-<VERSION>-nightly.yaml
│   └── redhat-chaos-prow-scripts-main__<VERSION>-nightly-x86-cpou-upgrade-<INITIAL>.yaml
├── cerberus/                       # Cerberus monitoring configurations
└── lp-chaos/                       # Long-polling chaos configurations
```

## Quick Start - Creating New Version Jobs

To create chaos jobs for a new OCP version, use the helper scripts:

```bash
cd ci-operator/config/redhat-chaos/prow-scripts

# Create nightly, ROSA, and CR chaos jobs for 4.21
scripts/create_chaos_jobs.sh 4.21

# Create upgrade chaos jobs for 4.20 -> 4.21
scripts/create_upgrade_chaos_jobs.sh 4.21
```

These scripts automatically:
- Copy configuration from the prior version
- Update all version references
- Update TELEMETRY_GROUP, image names, and TicketIds
- Update the variant in metadata

## Glossary

- **Krkn**: The chaos engineering tool used for OpenShift chaos testing (formerly known as Kraken)
- **Cerberus**: Cluster health monitoring tool that runs alongside chaos tests
- **ROSA**: Red Hat OpenShift Service on AWS
- **HCP**: Hosted Control Plane (ROSA with hosted control planes)
- **CPOU**: Control Plane Only Update - upgrade only control plane nodes first
- **UDN**: User Defined Networks
- **IPSec**: IP Security for network encryption
- **Component Readiness (CR)**: Tests for component readiness verification
- **Nightly**: Tests running against nightly OCP builds
- **Telemetry Group**: Identifier for grouping test results in telemetry systems

## Configuration File Types

### 1. Nightly Chaos Tests
**Pattern**: `redhat-chaos-prow-scripts-main__<VERSION>-nightly.yaml`
**Purpose**: Standard chaos tests against nightly OCP builds
**Example**: `redhat-chaos-prow-scripts-main__4.20-nightly.yaml`

Contains various chaos test scenarios:
- `krkn-hub-tests` - Pod disruption scenarios
- `krkn-hub-node-tests` - Node disruption scenarios
- `krkn-hub-tests-udn` - UDN-specific chaos tests
- `krkn-hub-tests-aws-ipsec` - IPSec-enabled tests
- `krkn-hub-tests-compact` - Compact cluster tests
- `krkn-hub-tests-<N>nodes` - Scaled node tests (13, 37 nodes)
- Platform-specific tests (Azure, GCP, vSphere, IBMCloud)

### 2. Upgrade Chaos Tests
**Pattern**: `redhat-chaos-prow-scripts-main__<VERSION>-nightly-upgrade.yaml`
**Purpose**: Chaos tests during OCP upgrade process
**Example**: `redhat-chaos-prow-scripts-main__4.19-nightly-upgrade.yaml`

Contains upgrade scenarios with chaos injection:
- `chaos-aws-loaded-upgrade-<FROM>to<TO>-pod-scenarios`
- `chaos-aws-loaded-upgrade-<FROM>to<TO>-node-scenarios`
- `chaos-aws-ipsec-loaded-upgrade-<FROM>to<TO>-*`
- `chaos-gcp-loaded-upgrade-<FROM>to<TO>-*`
- `chaos-gcp-fipsetcd-loaded-upgrade-<FROM>to<TO>-*`
- `chaos-azure-multi-upgrade-<FROM>to<TO>-*`

### 3. ROSA Chaos Tests
**Pattern**: `redhat-chaos-prow-scripts-main__rosa-<VERSION>-nightly.yaml`
**Purpose**: Chaos tests for ROSA (Red Hat OpenShift on AWS)
**Example**: `redhat-chaos-prow-scripts-main__rosa-4.20-nightly.yaml`

Contains ROSA-specific scenarios:
- `krkn-tests-rosa` - Standard ROSA chaos tests
- `krkn-tests-rosa-node` - ROSA node disruption tests
- `krkn-tests-rosa-hcp` - ROSA Hosted Control Plane tests
- `krkn-rosa-hcp-node` - HCP node disruption tests

### 4. Component Readiness Tests
**Pattern**: `redhat-chaos-prow-scripts-main__cr-<VERSION>-nightly.yaml`
**Purpose**: Component readiness verification with chaos
**Example**: `redhat-chaos-prow-scripts-main__cr-4.20-nightly.yaml`

### 5. CPOU Upgrade Tests
**Pattern**: `redhat-chaos-prow-scripts-main__<VERSION>-nightly-x86-cpou-upgrade-<INITIAL>.yaml`
**Purpose**: Control Plane Only Update chaos tests
**Example**: `redhat-chaos-prow-scripts-main__4.18-nightly-x86-cpou-upgrade-4.16.yaml`

## Version Conventions

### base_images
```yaml
base_images:
  cerberus.prow:
    name: cerberus
    namespace: chaos
    tag: cerberus-prow
  cli:
    name: "<VERSION>"        # Match target version
    namespace: ocp
    tag: cli
  krkn.prow:
    name: krkn
    namespace: chaos
    tag: latest
  ocp-qe-perfscale-ci:
    name: ocp-qe-perfscale-ci
    namespace: ci
    tag: latest
  upi-installer:
    name: "<VERSION>"        # Match target version
    namespace: ocp
    tag: upi-installer
```

### releases
For nightly tests:
```yaml
releases:
  initial:
    integration:
      name: "<VERSION>"
      namespace: ocp
  latest:
    candidate:
      product: ocp
      stream: nightly
      version: "<VERSION>"
  multi-latest:
    candidate:
      architecture: multi
      product: ocp
      stream: nightly
      version: "<VERSION>"
```

For upgrade tests:
```yaml
releases:
  latest:
    release:
      architecture: amd64
      channel: fast
      version: "<INITIAL_VERSION>"
  target:
    candidate:
      architecture: amd64
      product: ocp
      stream: nightly
      version: "<TARGET_VERSION>"
```

### zz_generated_metadata
```yaml
zz_generated_metadata:
  branch: main
  org: redhat-chaos
  repo: prow-scripts
  variant: <VARIANT>         # e.g., "4.20-nightly", "rosa-4.20-nightly", "4.19-nightly-upgrade"
```

## Environment Variables

### Common Environment Variables
| Variable | Description | Example |
|----------|-------------|---------|
| `TELEMETRY_GROUP` | Telemetry grouping identifier | `prow-ocp-4.20` |
| `CHURN` | Enable workload churn | `"true"` or `"false"` |
| `GC` | Garbage collection | `"false"` |
| `ITERATION_MULTIPLIER_ENV` | Test iteration multiplier | `"11"` |
| `SPOT_INSTANCES` | Use spot instances | `"true"` or `"false"` |
| `PROFILE_TYPE` | Profile type | `reporting` |
| `BASE_DOMAIN` | AWS base domain | `aws.rhperfscale.org` |

### Platform-Specific Variables
**AWS:**
- `USER_TAGS`: AWS resource tags (e.g., `TicketId 420`)
- `COMPUTE_NODE_REPLICAS`: Number of compute nodes

**Azure:**
- `BASE_DOMAIN`: `qe.azure.devcluster.openshift.com`
- `COMPUTE_NODE_TYPE`: VM type (e.g., `Standard_D4s_v5`)
- `CONTROL_PLANE_INSTANCE_TYPE`: Control plane VM type

**GCP:**
- `COMPUTE_NODE_TYPE`: Machine type (e.g., `n2-standard-4`)

### ROSA-Specific Variables
- `CHANNEL_GROUP`: Release channel (`nightly`)
- `OPENSHIFT_VERSION`: OCP version
- `COMPUTE_MACHINE_TYPE`: EC2 instance type
- `HOSTED_CP`: Enable hosted control plane (`"true"`)
- `REPLICAS`: Number of worker replicas

## Observers

Common observers used in chaos tests:
```yaml
observers:
  enable:
  - redhat-chaos-cerberus                              # Cluster health monitoring
  - openshift-qe-cluster-density-v2-observer           # Workload density observer
  - redhat-chaos-pod-scenarios-random-system-pods-observer  # Pod chaos observer
  - redhat-chaos-node-disruptions-worker-outage-observer    # Node chaos observer
```

## Workflows and Chains

### Common Workflows
- `redhat-chaos-installer-aws` - AWS cluster installation
- `redhat-chaos-installer-aws-compact` - Compact AWS cluster
- `redhat-chaos-installer-aws-ipsec` - AWS with IPSec
- `redhat-chaos-installer-azure-ipi-ovn-ipsec` - Azure with IPSec
- `redhat-chaos-installer-gcp-ipi-ovn-etcd-encryption-fips` - GCP with FIPS
- `openshift-qe-installer-azure` - Azure installation
- `openshift-qe-installer-gcp` - GCP installation
- `rosa-aws-sts` - ROSA STS workflow
- `rosa-aws-sts-hcp` - ROSA HCP workflow

### Common Test Chains
- `redhat-chaos-krkn-hub-tests` - All pod disruption tests
- `redhat-chaos-krkn-hub-node-tests` - All node disruption tests
- `redhat-chaos-krkn-hub-etcd-tests` - etcd disruption tests
- `redhat-chaos-krkn-hub-control-plane-tests` - Control plane tests
- `redhat-chaos-krkn-hub-worker-node-tests` - Worker node tests
- `redhat-chaos-krkn-hub-ovn-disruption` - OVN network disruption
- `redhat-chaos-krkn-hub-prometheus-tests` - Prometheus disruption
- `redhat-chaos-krkn-hub-console-tests` - Console disruption
- `redhat-chaos-krkn-hub-cluster-disruption` - Cluster-wide disruption
- `redhat-chaos-krkn-hub-random-system-pods-disruption` - Random pod chaos

### Common Test Refs
- `redhat-chaos-start-krkn` - Start Krkn chaos engine
- `redhat-chaos-power-outage` - Power outage simulation
- `redhat-chaos-kubevirt-outage` - KubeVirt VM outage
- `redhat-chaos-pod-scenarios-prometheus-disruption` - Prometheus pod chaos
- `openshift-qe-cluster-density-v2` - Cluster density workload
- `openshift-qe-upgrade` - OCP upgrade

## Creating New Version Configurations

When creating chaos test configurations for a new OCP version:

### 1. Nightly Tests
Copy from previous version and update:
- All version references in `base_images` (cli, upi-installer)
- Version in `releases` section
- `TELEMETRY_GROUP` environment variable
- Image names in `images` section (e.g., `cerberus-main-prow-420` → `cerberus-main-prow-421`)
- `USER_TAGS` TicketId
- `variant` in `zz_generated_metadata`

### 2. Upgrade Tests
- Update `latest` release to new initial version
- Update `target` release to new target version
- Update job names (e.g., `418to419` → `419to420`)
- Update `variant` in metadata

### 3. ROSA Tests
- Update `OPENSHIFT_VERSION` environment variable
- Update `TELEMETRY_GROUP`
- Update `CLUSTER_TAGS` TicketId
- Update image names and variant

### 4. Component Readiness Tests
- Update version in releases
- Update `TELEMETRY_GROUP`
- Update variant

## Verify Changes

After making any changes:

1. **Validate YAML syntax**
   ```bash
   yamllint <filename>
   ```

2. **Run make commands**
   ```bash
   make jobs     # Generate Prow jobs from configs
   make update   # Update all generated artifacts
   ```

3. **Check for version consistency**
   - Ensure all version references match
   - Verify telemetry groups are updated
   - Confirm image names reflect the version

## Related Documentation

- [OpenShift CI Documentation](https://docs.ci.openshift.org/)
- [Krkn Documentation](https://github.com/redhat-chaos/krkn)
- [Cerberus Documentation](https://github.com/redhat-chaos/cerberus)
- [Step Registry](../../step-registry/) - Reusable test components

