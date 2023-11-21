# jaegertracing-jaeger-operator-main-tests<!-- omit from toc -->

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

- **Repository**: [jaegertracing-jaeger-operator-tests](https://github.com/jaegertracing/jaeger-operator/blob/main/CONTRIBUTING.md#runing-the-e2e-tests)
- **Operator Tested**: [Jaeger Operator](https://github.com/jaegertracing/jaeger-operator)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Jaeger Operator E2E tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Jaeger Operator scenario can be broken into the following basic steps:

Testing with released Jaeger Operator version with unreleased OpenShift version:

1. Build the Jaeger tests assert image used for the E2E tests.
2. Build the containerized Jaeger tests executor image.
3. Provision a OpenShift cluster on AWS.
4. Install the Jager, Elasticsearch, AMQ streams and OpenTelemetry.
5. Run the Jaeger Operator tests.
6. Gather the results.
7. Deprovision the cluster.

Testing with unreleased Jaeger operator with supported OpenShift versiosn and configurations:

1. Build the Jaeger Operator image.
2. Build the Jaeger tests assert image used for the E2E tests.
3. Build the containerized Jaeger tests executor image.
4. Build the Jaeger Operator bundle.
5. Provision a OpenShift cluster on AWS.
6. Install the Jaeger Operator bundle built in the previous step.
7. Install the Elasticsearch, AMQ streams and OpenTelemetry.
8. Run the Jaeger Operator tests.
9. Gather the results.
10. Deprovision the cluster. 

### Cluster Provisioning and Deprovisioning:

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results

Following the test cluster being provisioned, the following steps are executed:

1. [`operatorhub-subscribe-elasticsearch-operator-ref`](../../../step-registry/operatorhub/subscribe/elasticsearch-operator/README.md)
2. [`operatorhub-subscribe-amq-streams-ref`](../../../step-registry/operatorhub/subscribe/amq-streams/README.md)
3. [`distributed-tracing-install-opentelemetry-product-ref`](../../../step-registry/distributed-tracing/install/opentelemetry-product/README.md)
4. [`distributed-tracing-install-jaeger-product-ref`](../../../step-registry/distributed-tracing/install/jaeger-product/README.md)
5. [`distributed-tracing-tests-jaeger-ref`](../../../step-registry/distributed-tracing/tests/jaeger/README.md)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The [`firewatch-ipi-aws` workflow](../../../step-registry/firewatch/ipi/aws/firewatch-ipi-aws-workflow.yaml) will fail.
- `EO_SUB_CHANNEL`
  - **Definition**: The operator subscription channel from which to install the Elasticsearch Operator.
  - **If left empty**: The [`operatorhub-subscribe-elasticsearch-operator`](../../../step-registry/operatorhub/subscribe/elasticsearch-operator/README.md) will use the `stable` channel.
- `EO_SUB_SOURCE`
  - **Definition**: The operator catalog source from which to install the Elasticsearch Operator.
  - **If left empty**: The [`operatorhub-subscribe-elasticsearch-operator`](../../../step-registry/operatorhub/subscribe/elasticsearch-operator/README.md) will use the `qe-app-registry` catalog source.


### Custom Images

- `jaeger-operator`
  - [Dockerfile](https://github.com/jaegertracing/jaeger-operator/blob/main/Dockerfile)
  - This Dockerfile is used to build a container image for the Jaeger Operator. It starts with a Golang base image and sets up the workspace. It then copies the Go Modules manifests and source code files into the container. The build process includes installing dependencies, setting build arguments, and compiling the Go code into a binary called "jaeger-operator." The final image is based on Red Hat Universal Base Image (UBI) and includes additional packages and setup steps. The entry point of the container is set to execute the "jaeger-operator" binary.
- `jaeger-tests-asserts-e2e`
  - [Dockerfile](https://github.com/jaegertracing/jaeger-operator/blob/main/Dockerfile.asserts)
  - This Dockerfile is used to build a container image for a set of testing tools. It starts with a Golang base image and sets up the workspace. It then copies the necessary files, including the Go Modules manifests and source code, and downloads the dependencies. The build process includes setting build arguments for the target operating system and architecture, and compiling multiple Go programs. The final image is based on the curlimages/curl image and includes the compiled binaries copied from the builder stage.
- `jaeger-tests-runner`
  - [Dockerfile](https://github.com/jaegertracing/jaeger-operator/blob/main/tests/Dockerfile)
  - This Dockerfile is designed to create a specialized image for running Jaeger Operator end-to-end tests in an OpenShift environment using Prow CI. It starts with a Golang base image and sets up the necessary environment. The repository files are copied into the image, and then kubectl and oc (OpenShift CLI) are installed. The working directory is set to the Jaeger Operator directory, and the Go path is configured. Required dependencies and tools are installed, including kuttl, golangci-lint, goimports, yq, kustomize, gomplate, and various scripts. Additionally, the go and cache directories are made writable to accommodate Prow CI restrictions.
- `jaeger-bundle`
  - [Dockerfile](https://github.com/jaegertracing/jaeger-operator/blob/main/bundle.Dockerfile)
  - This Dockerfile is used to build the Jaeger Operator bundle. It creates an image from scratch, indicating that it starts with an empty base. The labels define metadata for the bundle, including its media type, manifests, metadata, package, channels, and metrics. The COPY commands copy the bundle's manifests and metadata files to the appropriate locations as specified by the labels.
