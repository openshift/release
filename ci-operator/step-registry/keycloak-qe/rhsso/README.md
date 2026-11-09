# keycloak-qe-rhsso-test-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)


## Purpose

To provision the necessary infrastructure and using that infrastructure to execute RHSSO(Red Hat Single Sign-On) interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The RHSSO Core Interop scenario can be broken into the following basic steps:

1. Move the oc binary copied from the cli container to /usr/bin/oc on test container to be used to login to the test   cluster.
2. Set `OCP_PROJECT_NAME` name to namespace where rhsso operator is installed
3. add path for OC binary to System PATH variable
4. Execute tests via ansible playbook `test-ocp-ci-rhbk.yml`
4. copy the tests results to `$ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml`

## Prerequisite(s)
### Infrastructure
- A provisioned test cluster to target
- RHSSO operator must be installed on the test cluster

### Environment Variables


- `OCP_PROJECT_NAME`: keycloak-qe-rhsso-tests ref will require `OCP_PROJECT_NAME` to be set to keycloak or any other project name, but it needs to be same as install_namespace, otherwise tests will fail to execute.

