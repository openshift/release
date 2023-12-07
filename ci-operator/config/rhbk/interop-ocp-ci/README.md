# rhsso-interop-aws<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning - `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning---firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `rhsso-interop-aws`](#test-setup-execution-and-reporting-results---rhsso-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Test Repository**: [RHBK/interop-ocp-ci](https://github.com/rhbk/interop-ocp-ci.git)
- **Product Tested**: Red Hat Single Sign-On

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute RHSSO(Red Hat Single Sign-On) interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process


### Cluster Provisioning and Deprovisioning - `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws)documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `rhsso-interop-aws`

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`keycloak-qe-rhsso-tests-ref`](../../../step-registry/keycloak-qe/rhsso/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.

- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

- `OCP_PROJECT_NAME`: The [`keycloak-qe-rhsso-tests`](../../../step-registry/keycloak-qe/rhsso/README.md) ref will require `OCP_PROJECT_NAME` to be set to `keycloak or any other project name`, but it needs to be same as `install_namespace`, otherwise tests will fail to execute .


### Custom Images
- `rhsso-runner`
  - [Dockerfile](https://github.com/rhbk/interop-ocp-ci/blob/main/docker-container-executor/Dockerfile) - This image is used to execute RHSSO test suite. It basically copies the test repository (https://github.com/rhbk/interop-ocp-ci.git) into /tmp/tests/ansible-test directory on the container


