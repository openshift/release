# redhat-developer-helm-release-3.11<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `helm-interop-aws`](#test-setup-execution-and-reporting-results---helm-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)

## General Information

- **Repository**: [redhat-developer/helm](https://github.com/redhat-developer/helm/tree/release-3.11)
- **TestRepository**: [redhat-developer/helm-acceptance-testing](https://github.com/redhat-developer/helm-acceptance-testing/tree/helm-3.11-openshift)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Helm interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Helm Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the Helm binary
3. Execute  acceptance tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `helm-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

- The dockerfile to build the image is defined at https://github.com/redhat-developer/helm/blob/release-3.11/openshift-ci/Dockerfile.tests.
- After the image is built we are executing the `helm-acceptance-test` from the container root with the command `make -f openshift-ci/Makefile build test-acceptance`


## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
