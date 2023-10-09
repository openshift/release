# openshift-pipelines-install-and-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Custom Images](#custom-images)

## Purpose

To execute Openshift Pipelines interop tests. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run Openshift Pipelines interop tests
1. Login to the test cluster as a kubeadmin.
2. Run gauge command for olm.spec to install openshift pipelines operator.
3. Run other gauge specs for interop tests.
4. Move xmls to `${ARTIFACT_DIR}/junit_*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
 
### Environment Variables

- `OLM_CHANNEL`
  - **Definition**: OLM channel selected for openshift-pipelines operator.
  - **If left empty**: This step will use default value i.e., "latest".
  
## Custom Images

- `openshift-pipelines-runner`
  - [Dockerfile](https://github.com/openshift-pipelines/release-tests/blob/release-v1.11/Dockerfile)
  - The custom image for this step uses the quay.io/openshift-pipeline/ci as it's base image. The image has all the required dependencies installed to run the tests.