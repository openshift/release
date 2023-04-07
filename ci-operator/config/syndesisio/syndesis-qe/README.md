# syndesisio-syndesis-qe-1.15.x<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
    - [Test Setup, Execution, and Reporting Results - `fuse-online-interop-aws`](#test-setup-execution-and-reporting-results---fuse-online-interop-aws)
- [Prerequisite(s)](#prerequisites)
    - [Environment Variables](#environment-variables)
    - [Custom Images](#custom-images)

## General Information

- **Repository**: [syndesisio/syndesis-qe](https://github.com/syndesisio/syndesis-qe)
- **Operator Tested**: [Red Hat Fuse Online Operator](https://catalog.redhat.com/software/containers/fuse7/fuse-online-rhel8-operator/6048ded9122bd89307e013cb)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Fuse Online interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Fuse Online Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS.
2. Install the Fuse Online operator and deploy `syndesis-qe`.
3. Execute tests and archive results.
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `fuse-online-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`setup-syndesis-qe-env`](../../../step-registry/syndesisio/setup-syndesis-qe-env/README.md)
1. [`deploy-syndesis-qe`](../../../step-registry/syndesisio/deploy-syndesis-qe/README.md)
## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.

### Custom Images

- `fuse-online-test-runner`
    - [Dockerfile](https://github.com/syndesisio/syndesis-qe/blob/1.15.x/docker/Dockerfile)
    - The custom image for this step uses the [`alpine/git`](https://hub.docker.com/r/alpine/git) copied into `/tmp/syndesis-qe`.

