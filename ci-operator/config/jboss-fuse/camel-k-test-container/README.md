# jboss-fuse-camel-k-test-container-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `camel-k-interop-aws`](#test-setup-execution-and-reporting-results---camel-k-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [jboss-fuse/camel-k-test-container](https://github.com/jboss-fuse/camel-k-test-container)
- **Operator Tested**: [Camel K (Red Hat Integration - Camel K)](https://developers.redhat.com/topics/camel-k)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute Camel K interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `camel-k-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`camel-k-interop-tests`](../../../step-registry/camel-k/interop-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

### Custom Images

- `camel-k-runner`
  - [Dockerfile](https://github.com/jboss-fuse/camel-k-test-container/blob/main/Dockerfile)
  - The custom image for this step uses the docker.io/golang as it's base. The image should have all of the required dependencies installed to run the tests.