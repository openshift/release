# openshift-pipelines-install-and-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
- [Custom Images](#custom-images)

## Purpose

To execute Openshift Pipelines interop tests. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run Openshift Pipelines interop tests
1. Login to the test cluster as a kubeadmin.
2. Run other gauge specs for interop tests.
3. Move xmls to `${ARTIFACT_DIR}/junit_*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
  
## Custom Images

- `openshift-pipelines-runner`
  - [Dockerfile](https://github.com/openshift-pipelines/release-tests/blob/release-v1.11/Dockerfile)
  - The custom image for this step uses the quay.io/openshift-pipeline/ci as it's base image. The image has all the required dependencies installed to run the tests.