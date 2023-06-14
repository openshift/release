# 3scale-qe-3scale-deploy-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning--ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `3scale-amp-interop-aws`](#test-setup-execution-and-reporting-results---3scale-amp-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [3scale-qe/3scale-deploy](https://github.com/3scale-qe/3scale-deploy.git)
- **Operator Tested**: [3scale-amp (Red Hat 3scale API Management)](https://developers.redhat.com/products/3scale/overview)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute 3scale interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `ipi-aws`

The [`3scale-ipi-aws`](../../../step-registry/3scale/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with 3scale API Manager uninstallation step specific to the 3scale interop scenario.

The additional steps used in this workflow are as follows:

- **post steps**
  - [`3scale-apimanager-uninstall`](../../../step-registry/3scale/apimanager/uninstall/README.md)

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.

### Test Setup, Execution, and Reporting Results - `3scale-amp-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`3scale-apimanager-install`](../../../step-registry/3scale/apimanager/install/README.md)
3. [`3scale-interop-tests`](../../../step-registry/3scale/interop-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.
- `AWS_REGION`
  - **Definition**: AWS region where the bucket will be created for deploying 3scale API Manager.
  - **If left empty**: The [`3scale-apimanager-install`](../../../step-registry/3scale/apimanager/install/README.md) and [`3scale-apimanager-uninstall`](../../../step-registry/3scale/apimanager/uninstall/README.md) ref will fail.
- `DEPL_BUCKET_NAME`
  - **Definition**: The name of S3 bucket created for 3scale.
  - **If left empty**: The [`3scale-apimanager-install`](../../../step-registry/3scale/apimanager/install/README.md) and [`3scale-apimanager-uninstall`](../../../step-registry/3scale/apimanager/uninstall/README.md) ref will fail.
- `DEPL_PROJECT_NAME`
  - **Definition**: The namespace where 3scale is deployed. This should match with the namespace where 3scale operator is installed.
  - **If left empty**: The [`3scale-apimanager-install`](../../../step-registry/3scale/apimanager/install/README.md) ref, [`3scale-apimanager-uninstall`](../../../step-registry/3scale/apimanager/uninstall/README.md) ref and [`3scale-interop-tests`](../../../step-registry/3scale/interop-tests/README.md) ref will fail.

### Custom Images

- `3scale-runner`
  - [Dockerfile](https://github.com/3scale-qe/3scale-deploy/blob/main/Dockerfile)
- `3scale-interop-tests`
  - CI registry image mirrored from [quay](quay.io/rh_integration/3scale-interop-tests).