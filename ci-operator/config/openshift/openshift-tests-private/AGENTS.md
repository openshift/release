# AGENTS.md - Guide for AI Coding Agents

This file provides guidance for AI agents (like Claude Code) when working with openshift-tests-private CI configurations. It complements the human-focused README.md with agent-specific instructions and patterns.

## File Location
This file is located at: `ci-operator/config/openshift/openshift-tests-private/AGENTS.md`
Prow CI configuration files are located in `ci-operator/config/openshift/openshift-tests-private`

## Folder Structure Overview
```
openshift-tests-private/
├── tools/                          # Contains additional scripts for maintaining configuration files
│   ├── OWNERS                      # The tools folder's reviewers and approvers for github commit
│   ├── update-cron-entries.py      # Use this script to update all the job cron settings
│   ├── add_CPOU_upgrade_jobs.py
│   ├── add_missed_upgrade_jobs.py
│   ├── generate-cron-entry.sh
│   ├── get_missed_upgrade_jobs.py
│   └── jobs_heatmap_view.py
├── README.md                       # Prow CI documentation
├── OWNERS                          # The openshift-tests-private folder's reviewers and approvers for github commit
├── openshift-openshift-tests-private-release-<TARGET_VERSION>__<CPU_ARCH>-<IMAGE_STREAM>-<TARGET_VERSION>-upgrade-from-<IMAGE_STREAM>-<INITIAL_VERSION>.yaml
├── openshift-openshift-tests-private-release-<TARGET_VERSION>__<CPU_ARCH>-<IMAGE_STREAM>-<TARGET_VERSION>-cpou-upgrade-from-<INITIAL_VERSION>.yaml
└── openshift-openshift-tests-private-release-<VERSION>__<CPU_ARCH>-rollback-<IMAGE_STREAM>.yaml
└── openshift-openshift-tests-private-release-<VERSION>__<CPU_ARCH>-<IMAGE_STREAM>.yaml
```

## Glossary

- **Image Stream**: The OpenShift release channel (e.g., `nightly`, `stable`, `candidate`)
- **Initial Version**: The OpenShift version before the upgrade
- **Target Version**: The OpenShift version after the upgrade
- **CPU Architecture**: `amd64`, `arm64`, or `multi` (multi-arch)
- **f28/f60**: Job frequency in days (`f` stands for `frequency`, f28 = every 28 days, f60 = every 60 days)
- **Profile**: A combination of features/configurations for testing (e.g., ovn-ipsec, fips, proxy)
- **EOL**: End of Life - version no longer supported by Red Hat
- **SNO**: Single Node OpenShift
- **STS**: AWS Security Token Service
- **UPI**: User Provisioned Infrastructure
- **CPOU**: Control Plane Only update
- **TP**: TechPreview features

## E2E File Conventions

### 1. E2E File Definition
- E2E file names are in `openshift-openshift-tests-private-release-<VERSION>__<CPU_ARCH>-<IMAGE_STREAM>.yaml` format

### 2. To Multi-Arch Jobs
- To multi-arch jobs are used to test if the conversion from AMD64 or ARM64 architecture to multi-architecture succeeds
- The job name contains `to-multiarch`, for example: aws-ipi-ovn-ipsec-to-multiarch-f7

### Filename Examples
- openshift-openshift-tests-private-release-4.21__amd64-nightly.yaml
- openshift-openshift-tests-private-release-4.21__amd64-stable.yaml

## Upgrade File Conventions

### 1. Upgrade File Definition
- Y stream upgrade files, Z stream upgrade files, and Chain upgrade file names contain `upgrade`
- CPOU upgrade file names contain `cpou` and `upgrade`
- Rollback upgrade file names contain `rollback`

### 2. Target Version
- The first version behind `openshift-openshift-tests-private-release-` in the upgrade file name is the target version
- All jobs in an upgrade file are used to test the target OpenShift version

### 3. Canary Upgrade
- A canary update is an update strategy where worker node updates are performed in discrete, sequential stages instead of updating all worker nodes at the same time.
- Right now, we only implement canary upgrades as special Y stream upgrades
- Canary upgrade job names contain `canary`

### 4. Chain Upgrade
- Chain upgrades are a special type of upgrades where the initial version is two or more levels lower than the target version.

### 5. CPOU Upgrade
- CPOU is an abbreviation for Control Plane Only update.
- OpenShift only supports two consecutive even version CPOU upgrade, for example: upgrade from 4.12 to 4.13 to 4.14.

### 6. Rollback Upgrade
- Rollback upgrade is similar to Z stream upgrade but it is a downgrade, e.g., downgrade from 4.20.2 to 4.20.1
- The rollback upgrade's target version must be in the upgrade history, which means only historical versions can be downgraded to.

### 7. Y Stream Upgrade
- Y Stream Upgrade is the upgrade that upgrades from one level lower version to the target version, e.g. upgrade from 4.20.1 to 4.21.1

### 8. Z Stream Upgrade
- Z Stream Upgrade also known as Patch upgrade where the initial version and target version have the same minor version, e.g. upgrade from 4.20.1 to 4.20.2


### 9. Upgrade Jobs
- Upgrade jobs are defined as the `tests` items in an upgrade file
- Job name: the value of the root level `as` defines a job name
- Platform: each job must run on a platform, the first keyword in a job name specifies the platform
  - Examples: `aws-ipi-ovn-ipsec-f28`, `azure-mag-fips-f28`, `gcp-sno-f60`
  - Supported platforms: AWS, Azure, Baremetal, GCP, IBMCloud, Nutanix, vSphere
- Frequency: jobs run periodically, we use `-f{number}` in the job name to define the period
  - `f28` = every 28 days
  - `f60` = every 60 days
- Disconnected: if a job runs on a disconnected environment, its job name contains `disc`
  - Example: `aws-ipi-disc-priv-sts-f28`

### Filename Examples

**Y Stream Upgrade (4.20 → 4.21):**
`openshift-openshift-tests-private-release-4.21__amd64-nightly-4.21-upgrade-from-stable-4.20.yaml`

**Z Stream Upgrade (4.20.1 → 4.20.2):**
`openshift-openshift-tests-private-release-4.20__multi-nightly-4.20-upgrade-from-stable-4.20.yaml`

**Chain Upgrade (4.19 → 4.20 → 4.21):**
`openshift-openshift-tests-private-release-4.21__arm64-nightly-4.21-upgrade-from-stable-4.19.yaml`

**CPOU Upgrade:**
`openshift-openshift-tests-private-release-4.20__amd64-nightly-4.20-cpou-upgrade-from-4.18.yaml`

**Rollback:**
`openshift-openshift-tests-private-release-4.20__amd64-rollback-nightly.yaml`

## Upgrade Job Maintenance Strategies

When maintaining upgrade test jobs, follow these strategic guidelines to ensure comprehensive coverage while avoiding redundancy:

### Common Requirements for all Jobs
1. **Job Frequency**
   - Always use `f28` for Y stream upgrade jobs
   - Always use `f28` for Rollback upgrade jobs
   - Always use `f28` for Chain upgrade jobs
   - Always use `f28` for CPOU upgrade jobs
   - Always use `f60` for Z stream upgrade jobs

2. **Job Order**
    - Ensure all jobs are ordered alphabetically

3. **Disconnected profile distribution**
   - Run most disconnected profiles on **non-multi** architecture
   - Don't use disconnected profiles for chain upgrade jobs

4. **Multi-architecture preference**
   - Use multi-architecture for **at least 65%** of profiles

5. **ARM64 preference**
    - Try to use ARM64 architecture when possible

6. **TechPreview (TP) features**
    - TP jobs are **only supported for z-stream upgrades**

7. **Architecture-sensitive Features**
    - For profiles that include features affected by architecture, we copy them to all architectures
    - Architecture-sensitive features include storage (aws efs, gcp filestore-csi, bm LSO), mco, and cluster infrastructure

### Requirements for Chain Upgrade Jobs

1. **Applicable Versions**
   - Only latest version has Chain upgrade jobs

2. **Cross-platform, cross-feature, cross-architecture coverage**
   - Chain upgrade paths must cover all platforms: AWS, Azure, Baremetal, GCP, IBMCloud, Nutanix, vSphere
   - Chain upgrade jobs must cover all key features: sdn (4.15 and earlier; 4.14 default is OVN), sno, ovn, ipsec, ipv4, ipv6, dual-stack, fips, proxy, capability, sts, mixarch
   - Chain upgrade jobs must cover all CPU architectures: amd64, arm64, multiarch
   - Each selected profile should have at least one key feature

3. **EOL (End of Life) version handling**
   - Only keep one more release for EOL versions
   - Reference: [OpenShift Life Cycle Dates](https://access.redhat.com/support/policy/updates/openshift)

4. **Stable-to-stable upgrade paths**
   - Choose only ONE profile for stable-to-stable upgrade paths in chain upgrades
   - The profile should copy from stable-to-nightly

5. **Customer usage-driven coverage**
   - No need to cover versions not actively used by customers

6. **Not Applicable Features**
   Do not choose profiles containing below features for Chain upgrade jobs:
   - agent
   - disc
   - gpu
   - hypershift
   - longduration
   - longrun
   - rosa
   - to-multiarch
   - tp
   - winc

### Images in base_images
We run jobs in containers. To set up a container, we can put images in base_images in a configuration file.
There are some common images for which we need to use special versions. 

1. **ansible, cli, tools images**
   - For target versions **earlier than 4.6**: Use **target version** for ansible, cli, tools
   - For target versions **4.6 and newer**: Use **initial version** for ansible, cli, tools

2. **upi-installer, openstack-installer images**
   - **Always use initial version** regardless of OCP version

3. **Example**
   - base_images for openshift-openshift-tests-private-release-4.21__multi-stable-4.21-upgrade-from-stable-4.20.yaml
```
base_images:
  ansible:
    name: "4.20"
    namespace: ocp
    tag: ansible
  cli:
    name: "4.20"
    namespace: ocp
    tag: cli
  openstack-installer:
    name: "4.20"
    namespace: ocp
    tag: openstack-installer
  tools:
    name: "4.20"
    namespace: ocp
    tag: tools
  upi-installer:
    name: "4.20"
    namespace: ocp
    tag: upi-installer
```

### Versions in zz_generated_metadata
1. The `branch` always uses the target version
2. `variant` is in format <CPU_ARCH>-<IMAGE_STREAM>-<TARGET_VERSION>-upgrade-from-<IMAGE_STREAM>-<INITIAL_VERSION>

### Verify Changes
After making any changes, we should perform the following steps to ensure that all changes are correct:

1. **Update Job Frequency**
  - Run the `update-cron-entries.py` script to update cron settings based on job frequency

2. **Run Make Commands**
  - Always run `make update` commands to ensure configurations are valid:

### Quick Command Reference

```bash
# Generate Prow jobs from configs
make jobs

# Update all generated artifacts
make update
```

### Related Documentation

- Repository root CLAUDE.md - General repository structure
- [README.md](README.md) - Human-focused job naming and configuration guide
- [Step Registry](../../step-registry/) - Reusable test components
- [OpenShift CI Documentation](https://docs.ci.openshift.org/) - Official CI documentation
