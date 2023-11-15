# create-custom-mcp-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create cusom MachineConfigPool with a specified name. This step is necessary to deploy 'realtime' or '64k-pages' kernels in multi-arch clusters.


Example of a multi-arch cluster where a new MachineConfigPool named 'infra' has been created with one "arm64" node in it.

```
- as: aws-ipi-amd-mixarch-kerneltype-f28-day2-infra-custompool
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
      MCO_CONF_DAY2_CUSTOM_MCP_NAME: infra
      TAG_VERSION: '@4.15'
    test:
    - chain: ipi-install-heterogeneous-day2-kerneltype
    - chain: openshift-e2e-test-qe
    workflow: cucushift-installer-rehearse-aws-ipi
```


## Process

This script creates a MachineConfigPool resource and joins the nodes matching the given label to the new MachineConfigPool. We can decide how many node matching this label we want to add to the pool.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `MCO_CONF_DAY2_CUSTOM_MCP_NAME`
  - **Definition**: The name of the custom MachineConfigPool that will be created
  - **If left empty**: No custom MCP will be created and this step will be skipped
- `MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES`
  - **Definition**: The number of nodes that will be removed from the worker pool and added to the new custom pool
  - **If left empty**: It will default to 1. It the value is an empty string "" all nodes matching the MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL label will be added to the pool
- `MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL`
  - **Definition**: The label used to filter the nodes that can be added to the new pool. 
  - **If left empty**: It will default to "node-role.kubernetes.io/worker" label
- `MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT`
  - **Definition**: Maximum time that we will wait for the new custom pool to be updated
  - **If left empty**: It will default to 20m
