# camel-k-interop-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Custom Images](#custom-images)

## Purpose

To execute Camel K interop tests. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run Camel K interop tests:
1. Run `/opt/runTest.sh` script to execute tests.
2. Copy xmls file to `${ARTIFACT_DIR}/junit_*.xml`.
3. Copy logs file to `${ARTIFACT_DIR}`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a Camel K operator installed globally in `openshift-operators` namespace.

### Environment Variables

- `OLM_CHANNEL`
  - **Definition**: OLM channel selected for camelk operator.
  - **If left empty**: This step will use default value i.e., "latest".
  
## Custom Images

- `camel-k-runner`
  - [Dockerfile](https://github.com/jboss-fuse/camel-k-test-container/blob/main/Dockerfile)
  - The custom image for this step uses the docker.io/golang as it's base. The image should have all of the required dependencies installed to run the tests.