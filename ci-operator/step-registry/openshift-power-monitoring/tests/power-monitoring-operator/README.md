# openshift-power-monitoring-tests-kepler

<!--toc:start-->
- [openshift-power-monitoring-tests-kepler](#openshift-power-monitoring-tests-kepler)
  - [Purpose](#purpose)
  - [Process](#process)
  - [Prerequisite](#prerequisite)
    - [Infrastructure](#infrastructure)
<!--toc:end-->

## Purpose

To execute the `Power Monitoring Operator` [E2E tests](<https://github.com/openshift-power-monitoring/power-monitoring-operator/tree/v1alpha1/tests>) using the provided arguments. All the results will be copied into Artifact directory.

## Process

- Create a directory `/$ARTIFACT_DIR/test-run-logs` to store the test results.
- Validate the operator installation by checking the `rollout status` and waiting for `controller` deployment to be available.
- Execute the Operator e2e tests and capture the run inside `test-run-logs` directory. Log the events for `openshift-operators` as well as `openshift-kepler-operator` namespace while test run is executing.
- In case of any failure, gather OLM related resources, controller deployment related information and logs.

## Prerequisite

### Infrastructure

- A provisioned test cluster to target
- Kepler Operator installed.
