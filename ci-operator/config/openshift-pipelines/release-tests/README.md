# openshift-pipelines-release-tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `openshift-pipelines-interop-aws`](#test-setup-execution-and-reporting-results---openshift-pipelines-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [openshift-pipelines/release-tests](https://github.com/openshift-pipelines/release-tests)
- **Operator Tested**
  - [Red Hat OpenShift Pipelines](https://cloud.redhat.com/blog/cloud-native-ci-cd-with-openshift-pipelines)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute Openshift Pipelines interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `openshift-pipelines-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`openshift-pipelines-install-and-tests`](../../../step-registry/openshift-pipelines/install-and-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The `firewatch-ipi-aws` [workflow](../../../step-registry/firewatch/ipi/aws/README.md) will fail.

### Custom Images

- `openshift-pipelines-runner`
  - [Dockerfile](https://github.com/openshift-pipelines/release-tests/blob/release-v1.11/Dockerfile)
  - The custom image for this step uses the quay.io/openshift-pipeline/ci as it's base image. The image has all the required dependencies installed to run the tests.