# redhat-developer-devspaces-interop-tests-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `devspaces-interop-aws`](#test-setup-execution-and-reporting-results---devspaces-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
    - [redhat-developer/devspaces-interop-tests](https://github.com/redhat-developer/devspaces-interop-tests/tree/main)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute Devspaces interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `devspaces-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`devspaces-tests`](../../../step-registry/devspaces/tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.

### Custom Images

- `devspaces-runner`
    - [Dockerfile](https://github.com/redhat-developer/devspaces-interop-tests/blob/main/interop/Dockerfile)
    - The custom image for this step is related to devspaces qe test-suite installation and run. All the required dependencies are already included in the container.