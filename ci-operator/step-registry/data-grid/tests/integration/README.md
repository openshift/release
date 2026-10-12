# data-grid-tests-integration-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Custom Image](#custom-image)

## Purpose

Executes the integration tests for the Data Grid operator. All XML results will be copied to `$ARTIFACT_DIR`.

## Process

1. Retrieves the API URL for the ephemeral cluster and sets other required variables.
2. Copies the `$SHARED_DIR/kubeconfig` file to `/.kube/config` to be used by the tests.
3. Executes the Maven test suite using the provided variables and the profile.
4. Copies the JUnit results to `$ARTIFACT_DIR`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have `dg-integration` and `xtf-builds` namespaces.
  - Cluster monitoring should be enabled.
  - The Data Grid operator should be installed.

### Environment Variables

- `DG_TEST_NAMESPACE`
  - **Definition**: Namespace that the Data Grid tests should be executed in.
  - **If left empty**: `dg-integration` will be used.
- `DG_TEST_PROFILE`
  - **Definition**: Test profile to use when executing the Data Grid test suite.
  - **If left empty**: This variable is required.

## Custom Image
- `data-grid-runner`
  - [Dockerfile](https://github.com/infinispan/infinispan-operator/blob/stable/test-integration/Dockerfile)
    - The custom image for this scenario uses the [`maven:3.8-openjdk-11`](https://hub.docker.com/layers/library/maven/3.8-openjdk-11/images/sha256-37a94a4fe3b52627748d66c095d013a17d67478bc0594236eca55c8aef33ddaa?context=explore) image as it's base. The image should have all required dependencies installed and the [infinispan/infinispan-operator repository](https://github.com/infinispan/infinispan-operator) copied into `/infinispan-operator`.

