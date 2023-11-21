# distributed-tracing-tests-jaeger-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other:](#other)
- [Custom Image:](#custom-image)

## Purpose

Use to execute the `Jaeger E2E tests` [jaeger-e2e-tests](https://github.com/jaegertracing/jaeger-operator/tree/main/tests/e2e) using the provided arguments. All XML results will copied into "$ARTIFACT_DIR".

## Process

1. Set the options to exit the script on any error and to propagate pipeline failures.
2. Unset the `NAMESPACE` environment variable to avoid conflicts with `kuttl`.
3. Copy the `jaeger-operator` repository files from `/tmp/jaeger-operator` to a writable directory `/tmp/jaeger-tests` for use by `kuttl`.
4. Change the current directory to `/tmp/jaeger-tests`.
5. Download patched files required for running Jaeger tests on Prow CI, including `Makefile`, `run-e2e-test-suite.sh`, and `install-kuttl.sh`.
6. Run the `install-kuttl.sh` script to install `kuttl`.
7. Execute the end-to-end (e2e) tests by running the command `make run-e2e-tests` with various environment variables and options set.
8. Copy the generated test reports from `./reports` to the specified `$ARTIFACT_DIR`.
9. Check for the presence of a failure message in any file within `$ARTIFACT_DIR`.
10. If a failure message is found, display an error message and exit with a failure status.
11. If no failure message is found, display a success message.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
- The following operators installed.
  - Jaeger Operator.
  - OpenTelemetry Operator.

### Environment Variables

- `E2E_TESTS_TIMEOUT`
  - **Definition**: The timeout in seconds for the Jaeger tests.
  - **If left empty**: It will use "420" as the default value.

- `ASSERT_IMG`
  - **Definition**: The assert-e2e image used for testing.
  - **If left empty**: It will be empty by default.

### Other:

## Custom Image:

- [Dockerfile](https://github.com/jaegertracing/jaeger-operator/blob/main/tests/Dockerfile)

The Dockerfile is designed to build an image specifically for running Jaeger Operator end-to-end tests. The Dockerfile starts with a base image of golang:1.20 and sets the user to root. It creates the necessary directories and grants read and write permissions to all users. The repository files are then copied into the image. Additionally, it installs kubectl and oc tools, sets the working directory and Go path, and installs various required dependencies. Finally, it ensures that the required directories are writable as Prow CI doesn't allow the root user inside the container.
