# distributed-tracing-tests-opentelemetry-pre-upgrade-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other:](#other)
- [Custom Image:](#custom-image)

## Purpose

Use to execute the `OpenTelemetry E2E tests before running operator upgrade` [opentelemetry-e2e-tests](https://github.com/open-telemetry/opentelemetry-operator/tree/main/tests) using the provided arguments. All XML results will copied into "$ARTIFACT_DIR".

## Process

1. Create a directory `/tmp/kuttl-manifests` to store kuttl manifests.
2. Copy all files from `/tmp/opentelemetry-operator` to a new directory `/tmp/opentelemetry-tests` for kuttl to work with. Change the current working directory to `/tmp/opentelemetry-tests`.
3. Check for validity of the tests added in $SKIP_TESTS and remove the valid cases from test run. 
4. Execute the OpenTelemetry end-to-end (e2e) tests using kuttl:
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
  - **Definition**: The timeout in seconds for the OpenTelemetry tests.
  - **If left empty**: It will use "420" as the default value.

- `PARALLEL_TESTS`
  - **Definition**: The number of test cases to run in parallel.
  - **If left empty**: It will use "5" as the default value.

- `REPORT_NAME`
  - **Definition**: The name of the test report that will be added in the ARTIFACT_DIR.
  - **If left empty**: It will use "junit_opentelemetry_test_results.xml" as the default value.

- `MANIFEST_DIR`
  - **Definition**: One or more directories containing manifests to apply before running the tests.
  - **If left empty**: It will use "/tmp/kuttl-manifests" as the default value.

- `TARGETALLOCATOR_IMG`
  - **Definition**: The Target Allocator image used in testing".
  - **If left empty**: No image is set.
  
- `PRE_UPG_SKIP_TESTS`
  - **Definition**: Space seperated test cases to skip from the test run. Example "tests/e2e/smoke-targetallocator tests/e2e/prometheus-config-validation".
  - **If left empty**: tests/e2e-autoscale/autoscale tests/e2e/instrumentation-sdk tests/e2e/instrumentation-go tests/e2e/instrumentation-apache-multicontainer tests/e2e/instrumentation-apache-httpd tests/e2e/route tests/e2e/targetallocator-features tests/e2e/prometheus-config-validation tests/e2e/smoke-targetallocator tests/e2e-openshift/otlp-metrics-traces tests/e2e/instrumentation-nodejs tests/e2e/instrumentation-python tests/e2e/instrumentation-java tests/e2e/instrumentation-dotnet tests/e2e/smoke-init-containers will be skipped.

### Other:

## Custom Image:

- [Dockerfile](https://github.com/open-telemetry/opentelemetry-operator/blob/main/tests/e2e-openshift/Dockerfile)

The provided Dockerfile is designed to create a Docker image for running OpenTelemetry Operator end-to-end (e2e). It starts with the `golang:1.20` base image, copies the OpenTelemetry Operator repository files to the `/tmp/opentelemetry-operator` directory, installs the `kuttl` tool, and sets up the `kubectl` and `oc` utilities. The resulting image is prepared with the necessary environment and tools to execute the OpenTelemetry Operator e2e tests in an OpenShift environment.
