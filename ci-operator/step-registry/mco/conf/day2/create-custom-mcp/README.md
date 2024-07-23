# create-custom-mcp-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create cusom MachineConfigPools with the specified names. This step is necessary to deploy 'realtime' or '64k-pages' kernels in multi-arch clusters.

The step configuration consists on 3 space separated lista:

```
      MCO_CONF_DAY2_CUSTOM_MCP_NAME: list with all the names (the step will be skipped if empty)
      MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL: list with the labels used to create the pools defined in MCO_CONF_DAY2_CUSTOM_MCP_NAME (optional, if any pool doesn't have a corresponding label it will use the MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL value)
      MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES: list with the number of nodes that will be added to the pools defined in MCO_CONF_DAY2_CUSTOM_MCP_NAME (optional, if any pool doesn't have a corresponding number of nodes it will use the MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES value)

```


Valid lists examples

```
MCO_CONF_DAY2_CUSTOM_MCP_NAME: pool1 pool2 poo3

3 custom pools with 1 node each that will be taken from the worker pool
```

```
MCO_CONF_DAY2_CUSTOM_MCP_NAME: pool1 pool2
MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL: node-role.kubernetes.io/worker,kubernetes.io/arch=arm64
MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES: -1

2 custom pools. The first pool will include all worker nodes with arm64 arch. The second pool will have 1 node that will be taken from the worker pool.
```


```
MCO_CONF_DAY2_CUSTOM_MCP_NAME: pool1 pool2 poo3
MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES: 2 1 -1

3 custom pools. The first pool will have 2 nodes, the second one will have 1 node, and the third one will have all nodes left.
```


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
      MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL: node-role.kubernetes.io/worker,kubernetes.io/arch=arm64
      MCO_CONF_DAY2_CUSTOM_MCP_NAME: infra
    test:
    - chain: ipi-install-heterogeneous-day2-kerneltype
    - chain: openshift-e2e-test-qe
    workflow: cucushift-installer-rehearse-aws-ipi
```

Example for 2 custom machineconfigpools, one for amd64 with 2 nodes and another one for arm64 with 1 node

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
      MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL: node-role.kubernetes.io/worker,kubernetes.io/arch=arm64 node-role.kubernetes.io/worker,kubernetes.io/arch=amd64
      MCO_CONF_DAY2_CUSTOM_MCP_NAME: infraarm infraamd
      MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES: 1 2
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
  - **Definition**: Space separated list with the names of the custom MachineConfigPools that will be created
  - **If left empty**: No custom MCP will be created and this step will be skipped
- `MCO_CONF_DAY2_CUSTOM_MCP_NUM_NODES`
  - **Definition**: Space separated list with the number of nodes that will be removed from the worker pool and added to the new custom pools
  - **If left empty**: It will default to `MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES`. It the value is negative all nodes matching the pool's label will be added to the pool
- `MCO_CONF_DAY2_CUSTOM_MCP_FROM_LABEL`
  - **Definition**: Space separated list with the labels used to filter the nodes that can be added to the new pool. 
  - **If left empty**: It will default to `MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL`
- `MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT`
  - **Definition**: Maximum time that we will wait for the new custom pool to be updated
  - **If left empty**: It will default to 20m
- `MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_NUM_NODES.`
  - **Definition**: Default number of nodes that a pool will use if no number of nodes has been defined for it
  - **If left empty**: It will default to 1
- `MCO_CONF_DAY2_CUSTOM_MCP_DEFAULT_FROM_LABEL.`
  - **Definition**: Default label that will be used to create a pool if no label has been defined for it
  - **If left empty**: It will default to 1
