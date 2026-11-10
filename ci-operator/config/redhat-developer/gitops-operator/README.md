# Openshift Gitops operator- Interoperability Tests (v1.9 ocp4.14)<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - Openshift GitOps-interop-aws](#test-setup-execution-and-reporting-results---openshift-gitops-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)

## General Information

- **Repository**: [redhat-developer/gitops-operator](https://github.com/redhat-developer/gitops-operator)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Openshift GitOps interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Openshift GitOps Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the Openshift GitOps operator
3. Execute tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `Openshift GitOps-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`gitops-operator-tests`](../../../step-registry/gitops-operator/tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

