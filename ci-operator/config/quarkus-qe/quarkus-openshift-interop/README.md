# quarkus-qe-quarkus-openshift-interop<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `quarkus-interop-aws`](#test-setup-execution-and-reporting-results---quarkus-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **TestRepository**: [quarkus-qe/quarkus-openshift-interop](https://github.com/quarkus-qe/quarkus-openshift-interop)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute quarkus interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Quarkus Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Deploy and Execute tests and archive results
3. Deprovision the test cluster

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `quarkus-interop-aws`

Following the test cluster being provisioned, the following dockerfile is used to execute tests:

- The dockerfile to build the image and execute tests is defined at https://github.com/quarkus-qe/quarkus-openshift-interop/blob/main/openshift-ci/Dockerfile.

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `FIREWATCH_CONFIG`
  - **Definition**: The firewatch [configuration](https://github.com/CSPI-QE/firewatch/blob/main/docs/cli_usage_guide.md#defining-the-configuration) needed for firewatch tool to creates Jira issues for failed OpenShift CI jobs.

### Custom Images
