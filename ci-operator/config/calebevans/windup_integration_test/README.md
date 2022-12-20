# windup-windup_integration_test-main<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `cucushift-installer-rehearse-aws-ipi`](#cluster-provisioning-and-deprovisioning-cucushift-installer-rehearse-aws-ipi)
  - [Orchestrate, Execute, and Report - `mtr-scenario`](#orchestrate-execute-and-report---mtr-scenario)
- [Custom Images](#custom-images)
  - [`mtr-runner`](#mtr-runner)


## General Information

- **Repository**: [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git)
- **Operator Tested**: [MTR (Migration Toolkit for Runtimes)](https://developers.redhat.com/products/mtr/overview)
- **Maintainers**: Interop QE

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute MTR interop tests. The results of theses tests should be reported to the appropriate sources following execution.

## Process

The execution of this configuration can be thought of as a 3 step process (with many sub-processes in each step):
1. Provision the test cluster
2. Orchestrate, Execute, and Report
3. Deprovision the test cluster

These steps use a combination of workflows, chains, and refs to complete the interop testing of the MTR operator. This documentation will reference the `tests:` stanza of the configuration file quite a bit, so here is the stanza for convenience:

```yaml
tests:
- as: mtr-scenario
  steps:
    cluster_profile: aws-cspi-qe
    env:
      BASE_DOMAIN: aws.interop.ccitredhat.com
      SELENIUM_NAMESPACE: mtr
      SUB_INSTALL_NAMESPACE: mtr
      SUB_PACKAGE: mtr-operator
      SUB_SOURCE: redhat-operators
      SUB_TARGET_NAMESPACES: mtr
    test:
    - chain: interop-mtr
    workflow: cucushift-installer-rehearse-aws-ipi
```

### Cluster Provisioning and Deprovisioning: `cucushift-installer-rehearse-aws-ipi`

Please see the [`cucushift-installer-rehearse-aws-ipi`](https://steps.ci.openshift.org/workflow/cucushift-installer-rehearse-aws-ipi) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Orchestrate, Execute, and Report - `mtr-scenario`

All of the orchestration, test execution, and reporting for the interop MTR scenario is taken care of the by the [`interop-mtr`](../../../step-registry/interop/mtr/README.md) chain. All of the environment variables needed to execute this chain are passed to the chain using the `env` stanza. For more in-depth information on how the [`interop-mtr`](../../../step-registry/interop/mtr/README.md) chain and it' components work, please see the README that is hyperlinked in this paragraph.

## Custom Images

### `mtr-runner`

The `mtr-runner` image is a Python base image with all required packages for test execution installed along with the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository copied into the `/tmp/integration_tests` directory. The image is used to execute the MTR interop tests.

This configuration only utilizes one custom image. The Dockerfile for this image can be found in the `dockerfiles/interop` directory of the [windup/windup_integration_test](https://github.com/windup/windup_integration_test.git) repository or you can see it in the [`interop-mtr-execute-ref` README file.](../../../step-registry/interop/mtr/execute/README.md). The image is defined in the following stanza of the configuration:

```yaml
- context_dir: .
  dockerfile_path: dockerfiles/interop/Dockerfile
  to: mtr-runner
```