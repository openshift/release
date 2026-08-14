# jboss-fuse-fuse-xpaas-qe-container-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning--firewatch-ipi-aws)
    - [Test Setup, Execution, and Reporting Results - `jbossf-fuse--aws`](#test-setup-execution-and-reporting-results---jboss-fuse-interop-aws)
- [Prerequisite(s)](#prerequisite--s-)
    - [Environment Variables](#environment-variables)
    - [Custom Images](#custom-images)

## General Information

- **Repositories Used**
    - [jboss-fuse/fuse-xpaas-qe-container](https://github.com/jboss-fuse/fuse-xpaas-qe-container)

## Purpose

To provision the necessary infrastructure and use that infrastructure to execute Jboss Fuse interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

The [`firewatch-ipi-aws`](../../../step-registry/firewatch/ipi/aws/README.md) workflow is essentially a copy of the `ipi-aws` workflow with [firewatch-report-issues](../../../step-registry/firewatch/report-issues/firewatch-report-issues-ref.yaml) added in post steps.

### Test Setup, Execution, and Reporting Results - `jboss-fuse-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`jboss-fuse-deploy-resources`](../../../step-registry/jboss-fuse/deploy-resources/README.md)
2. [`jboss-fuse-run-tests`](../../../step-registry/jboss-fuse/run-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `FUSE_RELEASE`
    - **Definition**: Release related to Fuse version and test-suite image tag as well [XpaaS QE Image tags](https://quay.io/repository/rh_integration/xpaas-qe?tab=tags) 
    
### Custom Images

- `xpaas-qe`
    - [Dockerfile](https://github.com/jboss-fuse/fuse-xpaas-qe-container/blob/main/Dockerfile)
    - The custom image for this step is related to xpaas-qe test-suite installation and run. All the required dependencies are already included in the container.