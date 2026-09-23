# rh-messaging-qe-claire-lpt<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--frewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `amq-broker-interop-aws`](#test-setup-execution-and-reporting-results---amq-broker-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
  - [rh-messaging-qe/claire/lpt](https://github.com/rh-messaging-qe/claire/tree/lpt)
- **Operator Tested**: [Red Hat AMQ Broker)](https://developers.redhat.com/products/amq/overview)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute AMQ Broker interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.
The additional steps used in this workflow are as follows:

### Test Setup, Execution, and Reporting Results - `amq-broker-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`amq-broker-install-and-tests`](../../../step-registry/amq-broker/install-and-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.

### Custom Images

- `amq-broker-test-image`
  - CI registry image mirrored from [quay.io](quay.io/rhmessagingqe/claire:amq-broker-lpt).