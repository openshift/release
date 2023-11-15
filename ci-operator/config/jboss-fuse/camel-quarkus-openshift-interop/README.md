# camel-quarkus-interop-aws-main<!-- omit from toc -->

## General Information

- **Repository for interop testings**: [jboss-fuse/camel-quarkus-openshift-interop](https://github.com/jboss-fuse/camel-quarkus-openshift-interop/tree/main)
- **Camel-Quarkus official test suite repository**: [camel-q/camel-q-test-suite](https://gitlab.cee.redhat.com/jboss-fuse-qe/camel-q/camel-q-test-suite)

## Purpose

During the run CI takes the Dockerfile from `camel-quarkus-openshift-interop/openshift-ci` folder, builds an image from it and runs tests from [Camel Quarkus TS](https://gitlab.cee.redhat.com/jboss-fuse-qe/camel-q/camel-q-test-suite) modules defined by `$PROJECTS` variable.

## Process

This scenario can be broken into the following basic steps:

1. Pull `camel-quarkus-qe-test-container` test image
2. Provision test cluster on AWS using the `firewatch-ipi-aws` workflow
3. Execute tests and collect results to artifacts dir
4. Deprovision a test cluster.

### Cluster Provisioning and Deprovisioning: `firewatch-ipi-aws`

Please see the [`firewatch-ipi-aws`](https://steps.ci.openshift.org/workflow/firewatch-ipi-aws) documentation for more information on this workflow. This workflow is maintained by the Interop QE team.

### Test Setup, Execution, and Reporting Results - `camel-quarkus-interop-aws`

Please see the [`step-registry/camel-quarkus/execute-tests/README.md`](../../../step-registry/camel-quarkus/execute-tests/README.md) documentation for the `camel-quarkus-execute-tests` information about scenarios testsing ref.

Results are posted into `#camel-quarkus-qe` channel in `redhat-internal` Slack, and new issue in [CEQ Jira](https://issues.redhat.com/projects/CEQ/summary) is created automatically for every failure. 

Job history can be accessed from the [Prow Dashboard](https://prow.ci.openshift.org/job-history/gs/origin-ci-test/logs/periodic-ci-jboss-fuse-camel-quarkus-openshift-interop-main-camel-quarkus-ocp4.14-lp-interop-camel-quarkus-interop-aws) 
or via [dashboard](https://testgrid.k8s.io/redhat-openshift-lp-interop-release-4.14-informing#periodic-ci-jboss-fuse-camel-quarkus-openshift-interop-main-camel-quarkus-ocp4.14-lp-interop-camel-quarkus-interop-aws)

## Prerequisite(s)

### Environment Variables

- `BASE_DOMAIN`
  - **Definition**: A fully-qualified domain or subdomain name. The base domain of the cloud provider is used for setting baseDomain variable of the install configuration of the cluster.
  - **If left empty**: The `firewatch-ipi-aws` will fail.

### Custom Images

- `camel-quarkus-runner`
  - [Dockerfile](https://github.com/jboss-fuse/camel-quarkus-openshift-interop/blob/main/openshift-ci/Dockerfile)
  - The test image contains all tests executions requirements; E.g. pulls directly from the maven.repository.redhat.com, not from an internal source, to be as close to real customer use-case as possible.