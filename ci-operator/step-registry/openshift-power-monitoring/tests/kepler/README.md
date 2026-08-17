# openshift-power-monitoring-tests-kepler

<!--toc:start-->
- [openshift-power-monitoring-tests-kepler](#openshift-power-monitoring-tests-kepler)
  - [Purpose](#purpose)
  - [Process](#process)
  - [Prerequisite](#prerequisite)
    - [Infrastructure](#infrastructure)
<!--toc:end-->

## Purpose

To execute the `Kepler` [E2E tests](<https://github.com/openshift-power-monitoring/kepler/tree/main/e2e>) using the provided arguments. All the results will be copied into Artifact directory.

## Process

- Create a directory `/$ARTIFACT_DIR/test-run-logs` to store the test results.
- Validate the Kepler installation by checking the `rollout status` and waiting for `kepler` daemonsets to be available.
- Execute the e2e tests and capture the run inside `test-run-logs` directory. Log the events for `Kepler` namespace while test run is executing.
- In case of any failure, gather kepler daemonset related information and logs.

## Prerequisite

### Infrastructure

- A provisioned test cluster to target
- Kepler installed.
