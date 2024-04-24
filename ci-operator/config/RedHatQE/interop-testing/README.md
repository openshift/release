# Openshift CNV+ODF Interop Interoperability Tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`](#cluster-provisioning-and-deprovisioning-firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - Openshift GitOps-interop-aws](#test-setup-execution-and-reporting-results---openshift-gitops-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)

## General Information

- **Repository**: [RedHatQE/interop-testing](https://github.com/RedHatQE/interop-testing)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Openshift CNV_ODF interop tests.
The results of these tests will be reported to the appropriate sources following execution.

## Process

The Openshift CNV+ODF Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the ODF and CNV Operators
3. Setup ODF StorageSystem and used it a the default StorageClass for CNV
3. Execute tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `Openshift GitOps-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`deploy-odf`](../../../step-registry/interop-tests/deploy-odf/README.md)
1. [`ocs-tests`](../../../step-registry/interop-tests/ocs-tests/README.md)
1. [`deploy-cnv`](../../../step-registry/interop-tests/deploy-cnv/README.md)
1. [`cnv-tests-e2e-deploy`](../../../step-registry/interop-tests/cnv-tests-e2e-deploy/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
