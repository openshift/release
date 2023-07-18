# mta-tests-ui-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->


## Purpose

Used to execute the Cypress [tackle-ui-tests](https://github.com/konveyor/tackle-ui-tests) using the provided arguments. All XML results will be combined into `$ARTIFACT_DIR/junit_tackle_ui_results.xml`

## Process

1. Retrieves the the test cluster host URL from the `$SHARED_DIR` and uses it to construct the target URL of the MTA webpage in the test cluster.
2. Executes the Cypress tests using target URL constructed earlier in the script and the `CYPRESS_SPEC` variable
3. Uses the `npm run mergereports` command to merge all of the XML results into one file.
4. Copies the XML file from the command in step 3 to `$ARTIFACT_DIR/junit_tackle_ui_results.xml`.
5. If the tests fail and create screenshots, the screenshots get copied into `$ARTIFACT_DIR/screenshots/`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `mta` namespace/project with:
    - [The `mta-operator` installed](../../../install-operators/README.md).
    - [Tackle deployed](../../deploy-tackle/README.md).

### Environment Variables

- `MTA_TESTS_UI_SCOPE`
  - **Definition**: Tag you'd like to use to execute Cypress.
  - **If left empty**: It will use `@interop` as the default value.
- `CYPRESS_SPEC`
  - **Definition**: Value used for the `--spec` argument in the `cypress run` command.
  - **If left empty**: It will use `**/*.test.ts` by default.