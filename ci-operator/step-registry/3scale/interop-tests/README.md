# 3scale-interop-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To execute 3scale interop tests using the provided arguments. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run 3scale interop tests:
1. Sets `NAMESPACE` variable to `$DEPL_PROJECT_NAME` where 3scale is installed.
2. Run `make smoke` command to execute tests.
3. Copy xml test-results file to `${ARTIFACT_DIR}/junit_3scale_smoke.xml`.
4. Copy html test-results file to `${ARTIFACT_DIR}`

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a 3scale operator installed.
  - API Manager should be deployed for 3scale.

### Environment Variables

- `DEPL_PROJECT_NAME`
  - **Definition**: Namespace where the 3scale will be deployed. This should match with the namespace where 3scale operator is installed.
  - **If left empty**: This step will fail.
- `_3SCALE_TESTS_ssl_verify`
  - **Definition**: Boolean value to verify SSL while connecting to API Manager for running 3scale tests.
  - **If left empty**: This default value is `false`.
