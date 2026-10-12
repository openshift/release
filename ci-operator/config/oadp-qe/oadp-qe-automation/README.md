# odp-qe-oadp-qe-automation-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `oadp-ipi-aws`](#cluster-provisioning-and-deprovisioning-oadp-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `oadp-interop-aws`](#test-setup-execution-and-reporting-results---oadp-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [oadp-qe/oadp-qe-automation](https://github.com/oadp-qe/oadp-qe-automation)
  - [oadp-qe/oadp-e2e-qe](https://github.com/oadp-qe/oadp-e2e-qe)
  - [oadp-qe/oadp-apps-deployer](https://github.com/oadp-qe/oadp-apps-deployer)
  - [oadp-qe/mtc-python-client](https://github.com/oadp-qe/mtc-python-client)
- **Operator Tested**: [OADP (OpenShift API for Data Protection)](https://github.com/openshift/oadp-operator)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute OAPD interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `oadp-ipi-aws`

The `oadp-ipi-aws` workflow is essentially a copy of the `ipi-aws` workflow with additional steps to provision and deprovision an AWS S3 bucket required by the scenario.

The additional steps used in this workflow are as follows:

- **pre steps**
  - [`oadp-s3-create`](../../../step-registry/oadp/s3/create/README.md)
- **post steps**
  - [`oadp-s3-destroy`](../../../step-registry/oadp/s3/destroy/README.md)

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information regarding the steps that are not either of the steps explained above as they are not maintained by the CSPI QE team.

### Test Setup, Execution, and Reporting Results - `oadp-interop-aws`

For each of the following versions of the OADP operator, these steps are executed in this order immediately after the the test cluster is provisioned:

- **OADP v1.0.x**
  1. [`install-operators`](../../../step-registry/install-operators/README.md)
  2. [`oadp-execute-tests`](../../../step-registry/oadp/execute-tests/README.md)

- **OADP v1.1.x**
  1. [`install-operators`](../../../step-registry/install-operators/README.md)
  2. [`oadp-annotate-volsync`](../../../step-registry/oadp/annotate-volsync/README.md)
  3. [`oadp-execute-tests`](../../../step-registry/oadp/execute-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `OPERATORS`
  - **Definition**: A JSON list of operators to install. Please see the [Defining `OPERATORS`](../../../step-registry/install-operators/README.md#defining-operators) section of the `install-operators` documentation for more information.
  - **If left empty**: The [`install-operators`](../../../step-registry/install-operators/README.md) ref will fail.

### Custom Images

- `oadp-runner`
  - [Dockerfile](https://github.com/oadp-qe/oadp-qe-automation/blob/main/dockerfiles/testing/interop/Dockerfile)
  - This image is used to execute the OADP interop test suite(s). The image copies in the [oadp-qe/oadp-qe-automation](https://github.com/oadp-qe/oadp-qe-automation) repository as well as a tar archive of the [oadp-qe/oadp-e2e-qe](https://github.com/oadp-qe/oadp-e2e-qe), [oadp-qe/oadp-apps-deployer](https://github.com/oadp-qe/oadp-apps-deployer), and [oadp-qe/mtc-python-client](https://github.com/oadp-qe/mtc-python-client) repositories. These repositories are required to execute the tests but are private. Because cloning them would require maintaining a service account, it has been decided to promote an image for each repository in OpenShift CI and these images only really contain the tar archive of their respective repositories. Using the promoted images, we can just copy the archive out of each image and into the `oadp-runner` image.
