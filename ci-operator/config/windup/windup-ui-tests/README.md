# windup-windup-ui-tests-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `mtr-interop-aws`](#test-setup-execution-and-reporting-results---mtr-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [windup/windup-ui-tests](https://github.com/windup/windup-ui-tests)
- **Operator Tested**: [MTR (Migration Toolkit for Runtimes)](https://developers.redhat.com/products/mtr/overview)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute MTR interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The MTR Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the MTR operator and deploy Windup
3. Execute tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `mtr-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`mtr-deploy-windup-ref`](../../../step-registry/mtr/deploy-windup/README.md)
3. [`mtr-tests-ui-ref`](../../../step-registry/mtr/tests/ui/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.
- `MTR_TESTS_UI_SCOPE`
  - **Definition**: Tag you'd like to use to execute Cypress. This value will determine which set of tests to run. For example, for interop testing the value should be `interop`.
  - **If left empty**: It will use 'all' as the default value. Meaning all ui tests will execute.


### Custom Images

- `mtr-runner`
  - [Dockerfile](https://github.com/windup/windup-ui-tests/blob/main/dockerfiles/interop/Dockerfile)
  - The custom image for this step uses the [`cypress/base`](https://hub.docker.com/r/cypress/base) image as it's base. The image should have all of the required dependencies installed and the [windup/windup-ui-tests repository](https://github.com/windup/windup-ui-tests) copied into `/tmp/windup-ui-tests`.

