# rh-openjdk-test-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other](#other)
- [Custom Image - `rh-openjdk-runner`](#custom-image---rh-openjdk-runner)

## Purpose

Use to execute test script `run.sh` [rh-openjdk-test](https://github.com/rh-openjdk/jdkContainerOcpTests) using the provided arguments.".

## Process

1. Executes run.sh to deploy and test. 
2. Copies the XML results file and logs from the command in step 1 to `$ARTIFACT_DIR/test-run-results/opnjdk-$OPENJDK_VERSION`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `OPENJDK_VERSION`
  - **Definition**: Tag used to specify openjdk version to test. May be a list. Values separated by spaces (8 11 17)..
  - **If left empty**: It will use '11' as the default value. Meaning tests will be executed for the Openjdk 11.
- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Other


## Base Image - `rh-openjdk-runner`

- `rh-openjdk-runner`
  - [Dockerfile](https://github.com/rh-openjdk/jdkContainerOcpTests/blob/main/ContainerFile)
  - The base image for this step uses the [`Open JDK8 execution environment. This container is a base platform for building and running plain Java applications`](registry.redhat.io/ubi8/openjdk-8:latest) image as it's base. The image should have all of the required dependencies installed and the [rh-openjdk/jdkContainerOcpTests repository](https://github.com/rh-openjdk/jdkContainerOcpTests) copied into `/tmp/rhscl_openshift_dir/openjdks`. The image is mirrored from quay.io/rhopenjdkqa/rh_jdk_ocp_testsuite:latest

