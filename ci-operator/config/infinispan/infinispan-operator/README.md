# infinispan-infinispan-operator-stable<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `data-grid-interop-aws`](#test-setup-execution-and-reporting-results---data-grid-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [infinispan/infinispan-operator](https://github.com/infinispan/infinispan-operator)
- **Operator Tested**: [Data Grid](https://developers.redhat.com/products/red-hat-data-grid/overview)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute interop tests for the Data Grid operator. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Data Grid Interop scenario can be broken in to the following basic steps:

1. Provision a test cluster on AWS.
2. Prepare the test cluster after provisioning is complete.
3. Install the Data Grid operator.
4. Execute tests and archive results.
5. Deprovision the test cluster.

### Cluster Provisioning: `firewatch-ipi-aws`

This the `firewatch-ipi-aws` workflow is just an extention of the `ipi-aws` workflow. The only difference is the addition of the Firewatch tool for Jira reporting.

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup Execution, and Reporting Results - `data-grid-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`data-grid-prepare-cluster`](../../../step-registry/data-grid/prepare-cluster/README.md)
2. [`install-operators`](../../../step-registry/install-operators/README.md)
3. [`data-grid-tests-integration`](../../../step-registry/data-grid/tests/integration/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `DG_TEST_PROFILE`
  - **Definition**: The test profile you'd like to use to execute the tests in the [`data-grid-tests-integration`](../../../step-registry/data-grid/tests/integration/README.md) step of the scenario.
  - **If left empty**: The [`data-grid-tests-integration`](../../../step-registry/data-grid/tests/integration/README.md) step will not execute properly.
- `FIREWATCH_CONFIG`
  - **Definition**: The configuration you would like to use to execute the Firewatch tool.
  - **If left empty**: The Firewatch tool will fail.
- `FIREWATCH_DEFAULT_JIRA_PROJECT`
  - **Definition**: Where tickets will be filed if a failure doesn't match a rule in the `FIREWATCH_CONFIG` value.
  - **If left empty**: The Firewatch tool will fail.
- `FIREWATCH_JIRA_SERVER`
  - **Definition**: The server that tickets will be filed to when a failure is found.
  - **If left empty**: The Red Hat stage Jira server will be used.
- `FIREWATCH_FAIL_WITH_TEST_FAILURES`
  - **Definition**: Set so that the scenario shows as failed if test failures are found. This test suite does not do it on it's own, so firewatch will handle it.
  - **If left empty**: If the scenario runs and fails without this, it will still show as "passed" in our results.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

### Custom Images

- `data-grid-runner`
  - [Dockerfile](https://github.com/infinispan/infinispan-operator/blob/stable/test-integration/Dockerfile)
    - The custom image for this scenario uses the [`maven:3.8-openjdk-11`](https://hub.docker.com/layers/library/maven/3.8-openjdk-11/images/sha256-37a94a4fe3b52627748d66c095d013a17d67478bc0594236eca55c8aef33ddaa?context=explore) image as it's base. The image should have all required dependencies installed and the [infinispan/infinispan-operator repository](https://github.com/infinispan/infinispan-operator) copied into `/infinispan-operator`.