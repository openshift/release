# kerneltype-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create day-1 manifest files containing MachineConfigs that will deploy the given kerneltype in the given MachineConfigPools.

Example of an arm64 cluster that is booting using the 64k-pages kernel

```
- as: aws-ipi-kerneltype-f28-64k-pages
  cron: 14 4 13 * *
  steps:
    cluster_profile: aws-qe
    dependencies:
      OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: release:arm64-latest
    env:
      BASE_DOMAIN: qe.devcluster.openshift.com
      COMPUTE_NODE_TYPE: m6g.xlarge
      CONTROL_PLANE_INSTANCE_TYPE: m6g.xlarge
      E2E_RUN_TAGS: '@arm64 and @aws-ipi and @network-ovnkubernetes and not @fips'
      MCO_CONF_DAY1_INSTALL_KERNEL_TYPE: 64k-pages
      OCP_ARCH: arm64
      TAG_VERSION: '@4.15'
    test:
    - chain: openshift-e2e-test-qe
    workflow: cucushift-installer-rehearse-aws-ipi-kerneltype
```


## Process

This script creates a manifest file for each MachineConfigPool that we want to use the given kerneltype.

## Prerequisite(s)

### Infrastructure

### Environment Variables

- `MCO_CONF_DAY1_INSTALL_KERNEL_MCPS`
  - **Definition**: Space-separated list containing the names of the MachineConfigPools
  - **If left empty**:  It defaults to the "worker" pool
- `MCO_CONF_DAY1_INSTALL_KERNEL_TYPE`
  - **Definition**: Name of the kerneltype that will be installed. Allowed values ['realtime', '64k-pages']
  - **If left empty**:  No manifest file will be created and this step will be skipped
