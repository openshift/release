# AMQ Streams Interop Tests (main - 2.3.x)<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
    - [Cluster Provisioning and Deprovisioning: `ipi-aws`](#cluster-provisioning-and-de-provisioning)
    - [Test Setup, Execution, and Reporting Results](#test-setup-execution-and-reporting-results)
- [Prerequisite(s)](#prerequisites)
    - [Environment Variables](#environment-variables)
    - [Custom Images](#custom-images)

## General Information

- **Repository**: [strimzi/strimzi-kafka-operator](https://github.com/strimzi/strimzi-kafka-operator)
- **Operator Tested**: [Strimzi Kafka Operator (AMQ Streams)](https://strimzi.io)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute AMQ Streams interop tests. 
The results of these tests will be reported to the appropriate sources following execution.

## Process

The AMQ Streams Interop scenario can be broken into the following basic steps:

1. Provision a test cluster on AWS
2. Execute tests and archive results
3. De-provision a test cluster.

Note - Strimzi test suite itself installs the operator so users shouldn't specify the operator install step!

### Cluster Provisioning and De-provisioning

Please see the [`ipi-aws`](https://steps.ci.openshift.org/workflow/ipi-aws) documentation for more information on this workflow. 
This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed in this order:

1[`strimzi-run-tests-ref`](../../../step-registry/strimzi/run-tests/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
    - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
    - **If left empty**: The [`ipi-aws` workflow](../../../step-registry/ipi/aws/ipi-aws-workflow.yaml) will fail.
- `GROUPS`
    - **Definition**: Specify group of tests that will be executed via maven command. To pick up tests used for interop testing, users should use `sanity` group.
    - **If left empty**: It will use `sanity` as the [default value](../../../step-registry/strimzi/run-tests/README.md). Meaning only tests used for interop will be executed.
- `OLM_OPERATOR_CHANNEL`
    - **Definition**: Specify channel from where the operator should be installed.
    - **If left empty**: It will use `stable` channel that is used for latest released. Stable should be used only for main releases.

### Custom Images

- [strimzi-qe/strimzi-tests](https://quay.io/repository/strimzi-qe/strimzi-tests)
- To see Dockerfile, please contact someone from AMQ Streams QE.
