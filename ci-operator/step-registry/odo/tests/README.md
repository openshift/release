# odo-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Other](#other)
- [Custom Image - `oc-bin-image`](#custom-image---oc-bin-image)

## General Information

- **Repository**: [redhat-developer/odo](https://github.com/redhat-developer/odo)
- **Operator Tested**: [ODO (Developers CLI for OpenShift and Kubernetes)](https://developers.redhat.com/products/odo/overview)

## Purpose

Used to execute `scripts/openshiftci-presubmit-all-tests.sh` [odo-tests](https://github.com/redhat-developer/odo) using the provided arguments. All XML results files will be copied into "$ARTIFACT_DIR" and prepended with junit_.

## Process

1. Executes scripts/openshiftci-presubmit-all-tests.sh to deploy and test. 
2. Copies the XML results files from the command in step 1 to `$ARTIFACT_DIR` and prepends them with junit_.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables


### Other


## Custom Image - `oc-bin-image`

- `oc-bin-image`
  - [Dockerfile](https://github.com/redhat-developer/odo/blob/main/openshift-ci/build-root/Dockerfile)
