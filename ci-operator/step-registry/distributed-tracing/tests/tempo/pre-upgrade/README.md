# distributed-tracing-tests-tempo-pre-upgrade-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other:](#other)
- [Custom Image:](#custom-image)

## Purpose

Use to execute the `Tempo E2E tests` [tempo-e2e-tests](https://github.com/grafana/tempo-operator/tree/main/tests) using the provided arguments. All XML results will copied into "$ARTIFACT_DIR".

## Process

1. Create a directory `/tmp/kuttl-manifests` to store kuttl manifests and copy `/tmp/tempo-operator/minio.yaml` to the manifests directory.
2. Copy all files from `/tmp/tempo-operator` to a new directory `/tmp/tempo-tests` for kuttl to work with. Change the current working directory to `/tmp/tempo-tests`.
3. Check for validity of tests cases added in $SKIP_TESTS and remove the valid cases from test run.
4. Execute the Tempo Operator end-to-end (e2e) tests using kuttl:
   1. Set the `KUBECONFIG` environment variable to the value of `$KUBECONFIG`.
   2. Use kuttl to run the tests with the following options:
      - `--report=xml`: Generate an XML report of the test results.
      - `--artifacts-dir="$ARTIFACT_DIR"`: Specify the directory to store test artifacts.
      - `--parallel="$PARALLEL_TESTS"`: Run the tests in parallel, using the specified number of threads.
      - `--report-name="$REPORT_NAME"`: Set the name of the test report.
      - `--start-kind=false`: Do not start a new Kind cluster for the tests.
      - `--timeout="$TIMEOUT"`: Set the timeout for each test.
      - `--manifest-dir=$MANIFEST_DIR`: Specify the directory containing kuttl manifests.
   3. Run the tests in the `tests/e2e` and `tests/e2e-autoscale` directories.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
- The following operators installed.
  - Jaeger Operator.
  - OpenTelemetry Operator.
  - Tempo Operator

### Environment Variables

- `TIMEOUT`
  - **Definition**: The timeout in seconds for the Tempo tests.
  - **If left empty**: It will use "180" as the default value.

- `PARALLEL_TESTS`
  - **Definition**: The number of test cases to run in parallel.
  - **If left empty**: It will use "5" as the default value.

- `REPORT_NAME`
  - **Definition**: The name of the test report that will be added in the ARTIFACT_DIR.
  - **If left empty**: It will use "junit_tempo_test_results.xml" as the default value.

- `MANIFEST_DIR`
  - **Definition**: One or more directories containing manifests to apply before running the tests.
  - **If left empty**: It will use "/tmp/kuttl-manifests" as the default value.

- `PRE_UPG_SKIP_TESTS`
  - **Definition**: Space seperated test cases to skip from the test run. Example "tests/e2e/smoke-targetallocator tests/e2e/prometheus-config-validation".
  - **If left empty**: tests/e2e/smoketest-with-jaeger and tests/e2e-openshift/multitenancy will be skipped.

- `DOWNSTREAM_TESTS_COMMIT`
  - **Definition**: The Tempo operator commit which has downstream release compatible test cases.".
  - **If left empty**: The latest commit is used.

### Other:

## Custom Image:

- [Dockerfile](https://github.com/grafana/tempo-operator/blob/main/tests/Dockerfile)

The provided Dockerfile is designed to create a Docker image for running Tempo Operator end-to-end (e2e). It starts with the `golang:1.20` base image, copies the Tempo Operator repository files to the `/tmp/tempo-operator` directory, installs the `kuttl` tool, and sets up the `kubectl` and `oc` utilities. The resulting image is prepared with the necessary environment and tools to execute the Tempo Operator e2e tests in an OpenShift environment.
