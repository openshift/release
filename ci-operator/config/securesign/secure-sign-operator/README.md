# securesign-secure-sign-operator-main-tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning:](#cluster-provisioning-and-deprovisioning)
  - [Test Setup, Execution, and Reporting Results](#test-setup-execution-and-reporting-results)
- [Prerequisite(s)](#prerequisites)

## General Information

- **Repository**: [securesign-operator](https://github.com/securesign/secure-sign-operator)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Trusted Artifact Signer (TAS) Operator E2E tests.
The results of these tests will be reported to the appropriate sources following execution.

## Process

The TAS Operator scenario can be broken into the following basic steps:

Testing with unreleased TAS operator with nightly OpenShift version and configurations:

1. Build the TAS Operator image.
2. Build the TAS Operator bundle.
3. Provision an OpenShift cluster on AWS.
4. Install the TAS Operator bundle built in the previous step.
5. Run the TAS Operator tests.
6. Gather the results.
7. Deprovision the cluster. 

### Cluster Provisioning and Deprovisioning:

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

## Prerequisite(s)

### Environment Variables

### Custom Images

- `securesign-operator`
  - [Containerfile](https://github.com/securesign/secure-sign-operator/blob/main/Dockerfile)
  - This Dockerfile is used to build a container image for the TAS Operator.
- `securesign-bundle`
  - [Containerfile](https://github.com/securesign/secure-sign-operator/blob/main/bundle.Dockerfile)
  - This Dockerfile is used to build the TAS Operator bundle.
