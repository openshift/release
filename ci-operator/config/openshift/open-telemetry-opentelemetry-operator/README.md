# open-telemetry-opentelemetry-operator-main-tests<!-- omit from toc -->

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

- **Repository**: [opentelemetry-operator](https://github.com/open-telemetry/opentelemetry-operator/blob/main/CONTRIBUTING.md#end-to-end-tests)
- **Operator Tested**: [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute OpenTelemetry Operator E2E tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The OpenTelemetry Operator scenario can be broken into the following basic steps:

Testing released version of OpenTelemetry operator with unreleased OpenShift version.

1. Build the containerized OpenTelemetry tests executor image.
2. Provision a OpenShift cluster on AWS.
3. Install the OpenTelemetry, AMQ streams, Jaeger and Tempo operators.
4. Run the OpenTelemetry Operator tests.
5. Gather the results.
6. Deprovision the cluster.

Testing unreleased version of OpenTelemetry operator with supported OpenShift versions and configurations. 

1. Build the OpenTelemetry Operator image.
2. Build the containerized OpenTelemetry tests executor image.
3. Build the OpenTelemetry Operator bundle.
4. Provision a OpenShift cluster on AWS.
5. Install the OpenTelemetry Operator bundle built in the previous step.
6. Install the AMQ streams, Jaeger and Tempo operators.
7. Run the OpenTelemetry Operator tests.
8. Gather the results.
9. Deprovision the cluster. 

### Cluster Provisioning and Deprovisioning:

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed:

1. [`operatorhub-subscribe-amq-streams-ref`](../../../step-registry/operatorhub/subscribe/amq-streams/README.md)
2. [`distributed-tracing-install-opentelemetry-product-ref`](../../../step-registry/distributed-tracing/install/opentelemetry-product/README.md)
3. [`distributed-tracing-install-tempo-product-ref`](../../../step-registry/distributed-tracing/install/tempo-product/README.md)
4. [`distributed-tracing-install-jaeger-product-ref`](../../../step-registry/distributed-tracing/install/jaeger-product/README.md)
5. [`distributed-tracing-tests-tempo-ref`](../../../step-registry/distributed-tracing/tests/tempo/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `DOWNSTREAM_TESTS_COMMIT`
  - **Definition**: The OpenTelemetry operator commit to use downstream release compatible test cases.
  - **If left empty**: The [`distributed-tracing-tests-tempo`](../../../step-registry/distributed-tracing/tests/opentelemetry/README.md) will use the latest commit.


### Custom Images

- `opentelemetry-operator`
  - [Dockerfile](https://github.com/open-telemetry/opentelemetry-operator/blob/main/Dockerfile)
  - This Dockerfile is used to build the OpenTelemetry Operator image. It starts with a Golang base image and sets up the workspace. The Go Modules manifests are copied, and dependencies are cached to avoid re-downloading. The Go source files are then copied into the workspace. Build arguments are provided to set various version variables. Finally, the manager binary is built with the specified flags and configurations. The resulting image uses the distroless base image for minimal size and security, and the built manager binary is copied into the image. The entrypoint is set to execute the manager binary when the container starts.
- `opentelemetry-tests-runner`
  - [Dockerfile](https://github.com/open-telemetry/opentelemetry-operator/blob/main/Dockerfile)
  - This Dockerfile is designed to create an image specifically for executing OpenTelemetry Operator end-to-end (e2e) tests within an OpenShift environment using Prow CI. It starts with a Golang base image and copies the repository files into the /tmp/opentelemetry-operator directory. The working directory is set to /tmp/opentelemetry-operator. The image also installs the kuttl tool, which is used for testing, and sets up kubectl and oc command-line tools. This Dockerfile provides the necessary environment and dependencies to run the OpenTelemetry Operator e2e tests.
- `opentelemetry-bundle`
  - [Dockerfile](https://github.com/open-telemetry/opentelemetry-operator/blob/main/bundle.Dockerfile)
  - This Dockerfile creates a minimal image using the scratch base image. It is intended to build a bundle for the OpenTelemetry Operator. The image includes core bundle labels specifying metadata, manifests, package, channels, and metrics. Additionally, it includes labels for testing with scorecard. The Dockerfile copies the required files to the locations specified by the labels, including manifests, metadata, and scorecard tests. Overall, this Dockerfile sets up a minimal environment for packaging and testing the OpenTelemetry Operator bundle.
