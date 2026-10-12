# openshift-power-monitoring-kepler

<!--toc:start-->
- [openshift-power-monitoring-kepler](#openshift-power-monitoring-kepler)
  - [General Information](#general-information)
  - [Purpose](#purpose)
  - [Process](#process)
    - [Cluster Provisioning and Deprovisioning](#cluster-provisioning-and-deprovisioning)
    - [Test Setup, Execution and Reporting Results](#test-setup-execution-and-reporting-results)
  - [Custom Images](#custom-images)
<!--toc:end-->

## General Information

- **Repository**: [kepler-tests](<https://github.com/openshift-power-monitoring/kepler/tree/main/e2e>)
- **Application Tested**: [kepler](<https://github.com/openshift-power-monitoring/kepler>)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Power Monitoring Kepler E2E tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Power Monitoring Kepler scenario can be broken into the following steps:

- Build the Kepler image.
- Create the containerized tests executor image.
- Provision an OpenShift cluster:
  - PreSubmit (AWS cluster-pool)
  - PostSubmit (AWS, GCP)
  - Periodic (AWS, GCP)
- Install the Kepler that is built in the previous step.
- Run the Kepler tests.
- Gather the results.

### Cluster Provisioning and Deprovisioning

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution and Reporting Results

Following the test cluster provisioning, the below step are executed:

[`openshift-power-monitoring-tests-kepler`](../../../step-registry/openshift-power-monitoring/tests/kepler/README.md)

## Custom Images

- `kepler`

  - This [Dockerfile](https://github.com/openshift-power-monitoring/kepler/blob/main/build/Dockerfile) builds the Kepler image using Golang version 1.20.

- `kepler-tests-runner`
  - This [Dockerfile](https://github.com/openshift-power-monitoring/kepler/blob/main/e2e/Dockerfile) is designed to build and image for executing Kepler E2E tests within the OpenShift cluster using Prow CI. It starts with golang:1.20 as the base image, caches dependencies and copies the Go modules manifests. Along with that it adds binary for `oc` and `kubectl`. Finally, it adds the tests manifests and compile the test into `integration-test.test` binary.

