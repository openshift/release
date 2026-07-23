# jboss-fuse-csb-tnb-tests-container-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--firewatch-ipi-aws)
    - [Test Setup, Execution, and Reporting Results - `csb-interop-aws`](#test-setup-execution-and-reporting-results---csb-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
    - [Environment Variables](#environment-variables)
    - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
    - [jboss-fuse/csb-tnb-tests-container](https://github.com/jboss-fuse/csb-tnb-tests-container)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute Jboss Fuse interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `csb-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`csb-deploy-resources`](../../../step-registry/csb/deploy-resources/README.md)
2. [`csb-run-tests`](../../../step-registry/csb/run-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `CSB_RELEASE`
    - **Definition**: Release related to CSB version
- `CSB_PATCH`
    - **Definition**: CSB Examples GitHub repo and [GIT tags](https://github.com/jboss-fuse/camel-spring-boot-examples/tags) 

### Custom Images

- `tnb / tnb-tests`
    - [TNB Dockerfile](https://github.com/jboss-fuse/csb-tnb-tests-container/blob/main/tnb/Dockerfile)
    - [tnb-tests Dockerfile](https://github.com/jboss-fuse/csb-tnb-tests-container/blob/main/tnb-tests/Dockerfile)
    - The custom image for this step is related to *tnb-tests* test-suite installation and run. It make use of *tnb* image.  All the required dependencies are already included in the container.
- `remote mirrored images repositories`
  - [TNB](https://quay.io/repository/rh_integration/tnb?tab=tags)
  - [tnb-tests](https://quay.io/repository/rh_integration/tnb-tests?tab=tags)