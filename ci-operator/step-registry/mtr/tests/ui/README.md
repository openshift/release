# mtr-tests-ui-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other](#other)
- [Custom Image - `mtr-runner`](#custom-image---mtr-runner)

## Purpose

Use to execute the `Cypress` [windup-ui-tests](https://github.com/windup/windup-ui-tests) using the provided arguments. All XML results will be combined into "$ARTIFACT_DIR/junit_windup_ui_results.xml".

## Process

1. Retrieves the the test cluster host URL from the `$SHARED_DIR` and uses it to construct the target URL of the MTR webpage in the test cluster.
2. Executes the Cypress tests using target URL constructed earlier in the script and the `CYPRESS_SPEC` variable
3. Uses the `npm run mergereports` command to merge all of the XML results into one file.
4. Copies the XML file from the command in step 4 to `$ARTIFACT_DIR/junit_windup_ui_results.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `mtr` namespace/project with:
    - [The `mtr-operator` installed](../../../install-operators/README.md).
    - [Windup deployed](../deploy-windup/README.md).

### Environment Variables

- `MTR_TESTS_UI_SCOPE`
  - **Definition**: Tag you'd like to use to execute Cypress.
  - **If left empty**: It will use 'all' as the default value.
- `CYPRESS_SPEC`
  - **Definition**: Value used for the '--spec' argument in the 'cypress run' command.
  - **If left empty**: It will use "**/*.test.ts" by default.
- `BASE_DOMAIN`
  - **Definition**: BASE_DOMAIN value from the ipi-aws workflow. This is used to built the target URL
  - **If left empty**: This step will fail

### Other

- The [`retrieve-cluster-url`](../retrieve-cluster-url/README.md) ref should be run prior to this ref's execution.
  - The resulting `${SHARED_DIR}/cluster_url` file is required for this ref's execution.

## Custom Image - `mtr-runner`

- [Dockerfile](https://github.com/windup/windup-ui-tests/blob/main/dockerfiles/interop/Dockerfile)

The custom image for this step uses the [`cypress/base`](https://hub.docker.com/r/cypress/base) image as it's base. The image should have all of the required dependencies installed and the [windup/windup-ui-tests repository](https://github.com/windup/windup-ui-tests) copied into `/tmp/windup-ui-tests`.