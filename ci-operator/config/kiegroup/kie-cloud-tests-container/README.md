# kiegroup-kie-cloud-tests-container-main<!-- omit from toc -->


## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `rhba-interop-aws`](#test-setup-execution-and-reporting-results---rhba-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [kiegroup/kie-cloud-tests-container](https://github.com/kiegroup/kie-cloud-tests-container)
- **Operator Tested**: [Red Hat Business Automation Operator (RHPAM)](https://developers.redhat.com/products/rhpam/overview)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute kie-cloud-tests interop tests for RHPAM. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `rhba-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`rhba-interop-tests`](../../../step-registry/rhba/interop-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.

### Custom Images

- `rhba-runner`
  - [Dockerfile](https://github.com/kiegroup/kie-cloud-tests-container/blob/main/Dockerfile)
  - The custom image for this step uses the ubi8/openjdk-11 as it's base. The image should have all of the required dependencies installed to run the tests.