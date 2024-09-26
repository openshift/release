# web-terminal-interop<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning - `firewatch-rosa-aws-sts`](#cluster-provisioning-and-deprovisioning---firewatch-ipi-aws)
  - [Test Setup, Execution, and Reporting Results - `web-terminal-interop`](#test-setup-execution-and-reporting-results---rhsso-interop-aws)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Test Repository**: [eclipse-che/che](https://github.com/eclipse-che/che/tree/main/tests/e2e/specs/web-terminal.git)
- **Test suite docs**: [[WIP]](https://github.com/eclipse-che/che/pull/23127)
- **Product Tested**: Web Terminal Operator

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Web Terminal Operator interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process


### Cluster Provisioning and Deprovisioning - `firewatch-rosa-aws-sts`

Please see the [`firewatch-rosa-aws-sts`](https://steps.ci.openshift.org/workflow/firewatch-rosa-aws-sts)documentation for more information on this workflow.

### Test Setup, Execution - `web-terminal-interop`

1. [`install-operators`](../../../step-registry/install-operators/README.md)
2. [`che-e2e-tests-ref`](../../../step-registry/che-e2e/tests/che-e2e-tests-ref.yaml)

### Custom Images
- `e2e-che-interop`
  - [eclipse/e2e-che-interop:latest](quay.io/eclipse/e2e-che-interop:latest) - This image is used to execute the Web Terminal test suite.

### Reporting Results

- Tests results will be saved under the artifact dir as `test-results.xml` file.
- The weekly runs will be automatically reported to the `#wt-ci` Slack channel.