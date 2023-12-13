# kerneltype-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create a new MachineConfig that will deploy the given kerneltype in the given MachineConfigPools.

Example of a configuration of a multi-arch cluster where (after the installation) a new MachineConfigPool has been created and a new '64k-pages' kernel type has been applied to this pool.

```
- as: aws-ipi-amd-mixarch-kerneltype-f28-day2-64k-pages
  cron: 14 4 13 * *
  steps:
    cluster_profile: aws-qe
    dependencies:
      OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: release:multi-latest
    env:
      ADDITIONAL_WORKERS: "1"
      BASE_DOMAIN: qe.devcluster.openshift.com
      E2E_RUN_TAGS: '@heterogeneous and @aws-ipi and @network-ovnkubernetes and not
        @fips'
      MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL: node-role.kubernetes.io/worker,kubernetes.io/arch=arm64
      MCO_CONF_DAY2_CUSTOM_MCP_NAME: 64k-pages
      MCO_CONF_DAY2_INSTALL_KERNEL_MCPS: 64k-pages
      MCO_CONF_DAY2_INSTALL_KERNEL_TYPE: 64k-pages
      TAG_VERSION: '@4.15'
    test:
    - chain: ipi-install-heterogeneous-day2-kerneltype
    - chain: openshift-e2e-test-qe
    workflow: cucushift-installer-rehearse-aws-ipi
```


## Process

This script creates a MachineConfig for each MachineConfigPool that we want to use the given kerneltype. After the MachineConfig resources are created it will wait for all the nodes to apply the new kerneltype.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `MCO_CONF_DAY2_INSTALL_KERNEL_MCPS`
  - **Definition**: Space-separated list containing the names of the MachineConfigPools
  - **If left empty**:  It defaults to the "worker" pool
- `MCO_CONF_DAY2_INSTALL_KERNEL_TYPE`
  - **Definition**: Name of the kerneltype that will be installed. Allowed values ['realtime', '64k-pages']
  - **If left empty**:  No MachineConfig will be created and this step will be skipped
- `MCO_CONF_DAY2_INSTALL_KERNEL_TIMEOUT`
  - **Definition**: Maximum time that we will wait for a single pool to be updated with the new kernel.
  - **If left empty**: It will default to "20m"
