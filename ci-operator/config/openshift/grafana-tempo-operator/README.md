# grafana-tempo-operator-main-tests<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning:](#cluster-provisioning-and-deprovisioning)
  - [Test Setup, Execution, and Reporting Results](#test-setup-execution-and-reporting-results)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [grafana-tempo-operator-tests](https://github.com/grafana-operator/grafana-operator/blob/master/CONTRIBUTING.md#e2e-tests-using-kuttl)
- **Operator Tested**: [Tempo Operator](https://github.com/grafana-operator/grafana-operator)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Tempo Operator E2E tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Tempo Operator scenario can be broken into the following basic steps:

Testing released Tempo operator version with unreleased OpenShift version.

1. Build the Tempo Operator image.
2. Build the containerized Tempo tests executor image.
3. Build the Tempo Operator bundle.
4. Provision a OpenShift cluster on AWS.
5. Install the Tempo Operator bundle built in the previous step.
6. Install the OpenTelemetry operators.
7. Run the Tempo Operator tests.
8. Gather the results.
9. Deprovision the cluster.

Testing unreleased Tempo operator version with supported OpenShift versions and configuraiton.

1. Build the Tempo Operator image.
2. Build the containerized Tempo tests executor image.
3. Build the Tempo Operator bundle.
4. Provision a OpenShift cluster on AWS.
5. Install the Tempo Operator bundle built in the previous step.
6. Install the OpenTelemetry operators.
7. Run the Tempo Operator tests.
8. Gather the results.
9. Deprovision the cluster. 

### Cluster Provisioning and Deprovisioning:

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed.:

1. [`distributed-tracing-install-tempo-product-ref`](../../../step-registry/distributed-tracing/install/tempo-product/README.md)
2. [`distributed-tracing-install-opentelemetry-product-ref`](../../../step-registry/distributed-tracing/install/opentelemetry-product/README.md)
3. [`distributed-tracing-tests-tempo-ref`](../../../step-registry/distributed-tracing/tests/tempo/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `DOWNSTREAM_TESTS_COMMIT`
  - **Definition**: The Tempo operator commit to use downstream release compatible test cases.
  - **If left empty**: The [`distributed-tracing-tests-tempo`](../../../step-registry/distributed-tracing/tests/tempo/README.md) will use the latest commit.

### Custom Images

- `tempo-operator`
  - [Dockerfile](https://github.com/grafana/tempo-operator/blob/main/Dockerfile)
  - This Dockerfile builds the Tempo operator image using Golang version 1.20. It sets up the working directory, caches tool dependencies, and copies the Go Modules manifests and source code. It then builds the operator using the specified version. The resulting image uses the distroless base image, which provides a minimal environment, and copies the built manager binary. The user is set to a non-root user (65532:65532), and the entrypoint is configured to run the manager binary.
- `tempo-tests-runner`
  - [Dockerfile](https://github.com/grafana/tempo-operator/blob/main/tests/Dockerfile)
  - This Dockerfile is designed to build an image for executing Tempo Operator end-to-end (e2e) tests within the OpenShift release using Prow CI. It starts with the golang:1.20 base image, copies the repository files into the /tmp/tempo-operator directory, and sets the working directory accordingly. It installs kuttl, kubectl, and oc tools, necessary for the tests. Finally, it builds the required binaries using the make build command.
- `tempo-bundle`
  - [Dockerfile](https://github.com/grafana/tempo-operator/blob/main/bundle/openshift/bundle.Dockerfile)
  - This Dockerfile is used to create a minimal image from scratch for the Tempo Operator bundle. It starts from a blank slate and includes only the necessary files and labels. The core bundle labels define metadata about the bundle, such as the mediatype, manifests, metadata, package name, channels, and metrics information. Additionally, there are labels specific to testing, specifying the mediatype and configuration for scorecard tests. The Dockerfile copies the corresponding files to the locations specified by the labels, including the manifests, metadata, and scorecard test configuration files.
