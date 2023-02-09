# windup-windup-ui-tests-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-deprovisioning-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `mtr-interop-aws`](#test-setup-execution-and-reporting-results---mtr-interop-aws)
- [Custom Images](#custom-images)
  - [`mtr-runner`](#mtr-runner)

## General Information

- **Repository**: [windup/windup-ui-tests](https://github.com/windup/windup-ui-tests)
- **Operator Tested**: [MTR (Migration Toolkit for Runtimes)](https://developers.redhat.com/products/mtr/overview)
- **Maintainers**: Interop QE

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute MTR interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The MTR Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Install the MTR operator and deploy Windup
3. Execute tests and archive results
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `ipi-aws`

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `mtr-interop-aws`

Following the test cluster being provisioned, the following steps are executed in this order:

1. [`mtr-install-chain`](../../../step-registry/mtr/install/README.md)
2. [`mtr-deploy-windup-ref`](../../../step-registry/mtr/deploy-windup/README.md)
3. [`mtr-execute-interop-ui-tests-chain`](../../../step-registry/mtr/execute-interop-ui-tests/README.md)
4. [`lp-interop-tooling-archive-results-ref`](../../../step-registry/lp-interop-tooling/archive-results/README.md)

## Custom Images

### `mtr-runner`

- [Dockerfile](https://github.com/windup/windup-ui-tests/blob/main/dockerfiles/interop/Dockerfile)

The custom image for this step uses the [`cypress/base`](https://hub.docker.com/r/cypress/base) image as it's base. The image should have all of the required dependencies installed and the [windup/windup-ui-tests repository](https://github.com/windup/windup-ui-tests) copied into `/tmp/windup-ui-tests`.

