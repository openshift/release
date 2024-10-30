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
      MCO_CONF_DAY2_CUSTOM_MCP: '[{"mcp_name": "infra", "mcp_node_num": "1", "mcp_node_label":
        "node-role.kubernetes.io/worker=,kubernetes.io/arch=arm64"}]'
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
  - **Definition**: A json format of list string to define multiple custom MCPs. Example: `'[{"mcp_name": "infra", "mcp_node_num": "1", "mcp_node_label": "node-role.kubernetes.io/worker=,kubernetes.io/arch=arm64"}]'`. `mcp_name` element is required; `mcp_node_num` element is `1` by default; `mcp_node_label` element is `node-role.kubernetes.io/worker` by default. 
  - **If left empty**: No custom MCP will be created and this step will be skipped
- `MCO_CONF_DAY2_CUSTOM_MCP_TIMEOUT`
  - **Definition**: Maximum time that we will wait for the new custom pool to be updated
  - **If left empty**: It will default to 20m
