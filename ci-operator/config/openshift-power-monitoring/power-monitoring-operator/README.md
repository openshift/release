# openshift-power-monitoring-power-monitoring-operator

<!--toc:start-->
- [openshift-power-monitoring-power-monitoring-operator](#openshift-power-monitoring-power-monitoring-operator)
  - [General Information](#general-information)
  - [Purpose](#purpose)
  - [Process](#process)
    - [Cluster Provisioning and Deprovisioning](#cluster-provisioning-and-deprovisioning)
    - [Test Setup, Execution and Reporting Results](#test-setup-execution-and-reporting-results)
  - [Custom Images](#custom-images)
<!--toc:end-->

## General Information

- **Repository**: [power-monitoring-operator-tests](<https://github.com/openshift-power-monitoring/power-monitoring-operator/tree/v1alpha1/tests>)
- **Operator Tested**: [power-monitoring-operator](<https://github.com/openshift-power-monitoring/power-monitoring-operator>)

## Purpose

To provision the necessary infrastructure and using that infrastructure to execute Power Monitoring Operator E2E tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The Power Monitoring Operator scenario can be broken into the following steps:

- Build the Operator image.
- Create the containerized Operator tests executor image.
- Build the Operator bundle.
- Provision an OpenShift cluster:
  - PreSubmit (AWS cluster-pool)
  - PostSubmit (AWS, GCP)
  - Periodic (AWS, GCP)
- Install the Operator bundle that is built in the previous step.
- Run the Operator tests.
- Gather the results.

### Cluster Provisioning and Deprovisioning

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is not maintained by the Interop QE team.

### Test Setup, Execution and Reporting Results

Following the test cluster provisioning, the below step are executed:

[`openshift-power-monitoring-tests-kepler`](../../../step-registry/openshift-power-monitoring/tests/kepler/README.md)

## Custom Images

- `power-monitoring-operator`

  - This [Dockerfile](https://github.com/openshift-power-monitoring/power-monitoring-operator/blob/v1alpha1/Dockerfile) builds the Operator image using Golang version 1.20. It sets up the working directory, caches dependencies, and copies the Go modules manifests and source code. It then builds the operator using the specified OS and architecture. The user is set to non-root user (65532:65532) and the entrypoint is configured to run the manager binary.

- `kepler-tests-runner`
  - This [Dockerfile](https://github.com/openshift-power-monitoring/power-monitoring-operator/blob/v1alpha1/tests/Dockerfile) is designed to build and image for executing Operator E2E tests within the OpenShift cluster using Prow CI. It starts with golang:1.20 as the base image, caches dependencies and copies the Go modules manifests. Along with that it adds binary for `oc` and `kubectl`. Finally, it adds the tests manifests and compile the test into `e2e.test` binary.

- `kepler-bundle`
  - This [Dockerfile](https://github.com/openshift-power-monitoring/power-monitoring-operator/blob/v1alpha1/bundle.Dockerfile) is used to create an image from scratch for Operator bundle. It starts from a blank slate and includes only the necessary files and labels. The core bundle labels define metadata about the bundle such as `manifests`, `metadata`, `channels` etc. Additionally, there are labels specific to testing specifying the mediatype and configuration for scorecard tests. The Dockerfile copies the corresponding files to the location specified by the labels, including the manifests, metadata and scorecard.
