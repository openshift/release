# jboss-web-server-lp-interop-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)


## Purpose

To provision the necessary infrastructure and using that infrastructure to execute JWS(Jboss Web Server) interop tests. The results of these tests will be reported to the appropriate sources following execution.

## Process

The JWS Core Interop scenario can be broken into the following basic steps:

1. Create a namespace(jws-test-image) where you run the test pod that pulls the quay image.
2. Create two namspaces(jws-tests and jws-tests-build) , jws-tests namespace is used to execute jws tests
jws-tets-build is used by tests to build images during test execution
3. Create secrets to access images quay repository(credentials provided by JWS QE to pull test image from their quay repo), product images from registry.redhat.io
4. Create jws-test-pod that pulls test quay image
5. Set `OPENSHIFT_PROJECT_NAME`, `OPENSHIFT_AUTH_TOKEN`, `OPENSHIFT_CLUSTER_URL`, `OPENSHIFT_USERNAME`, `JWS_IMAGE_REGISTRY`, as environment variables for jws-test-pod since these are required by tests for successful execution
6. Provide the required pull credentials for test pod
7. copy the tests results to `$ARTIFACT_DIR/jws-artifacts/`

## Prerequisite(s)
### Infrastructure
- A provisioned test cluster to target
- JWS operator must be installed on the test cluster
- Quay Secrets must be present in the vault

### Test Image
- JWS test image - `quay.io/jbossqe-jws/pit-openshift-ews-tests`