# Red Hat Integration - Service Registry Interoperability Tests (main - 2.3.x)<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-de-provisioning)
    - [Test Setup, Execution, and Reporting Results](#test-setup-execution-and-reporting-results)
- [Prerequisite(s)](#prerequisites)
    - [Environment Variables](#environment-variables)
    - [Custom Image](#custom-images)

## General Information

- **Repository**: [Apicurio/apicurio-registry-system-tests](https://github.com/Apicurio/apicurio-registry-system-tests)
- **Operator Tested**: [Apicurio Registry Operator (Service Registry)](https://www.apicur.io/registry/)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Red Hat Integration - Service
Registry interoperability tests. The results of these tests will be reported to the appropriate sources following
execution.

## Process

The Service Registry interoperability scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS.
2. Execute tests and archive results.
3. De-provision a test cluster.

**Note:** Service Registry test suite itself installs the operator so users shouldn't specify the operator install step!

### Cluster Provisioning and De-provisioning

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this
workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`service-registry-run-tests-ref`](../../../step-registry/service-registry/run-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for
  setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.

### Custom Image

- [apicurio/apicurio-ci-tools](https://quay.io/repository/apicurio/apicurio-ci-tools)
- To see Dockerfile, please contact someone from Service Registry QE.
