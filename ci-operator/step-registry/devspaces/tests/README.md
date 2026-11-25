# devspaces-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
- [Custom Images](#custom-images)

## Purpose

To execute the devspaces interop test-suite. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run Fuse On Openshift interop tests:
1. Copies the kubeconfig to a writeable dir.
2. Logs in with oc login which will add a user token to the kubeconfig needed for tests.
3. Execute the devspaces test script [execute-test-harness.sh](https://github.com/redhat-developer/devspaces-interop-tests/blob/main/scripts/execute-test-harness.sh)
   1. This script will create a pod on the test cluster from a public test image which leads to the test execution happening on the test cluster.
   2. The pod stores the test results in a dir called test-run-results
4. We then copy those test results to the $ARTIFACT_DIR

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.


## Custom Images

- `devspaces-runner`
    - [Dockerfile](https://github.com/redhat-developer/devspaces-interop-tests/blob/main/interop/Dockerfile)
    - The custom image for this step is related to devspaces qe test-suite installation and run. All the required dependencies are already included in the container.