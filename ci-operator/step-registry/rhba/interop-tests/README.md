# rhba-interop-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
- [Custom Images](#custom-images)

## Purpose

To execute RHBA interop tests. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run RHBA interop tests:
1. Run `/opt/runTest.sh` script to execute tests.
2. Add 'junit_' prefix to all xml tests reports

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- `OLM_CHANNEL`
  - **Definition**: OLM channel selected for RHBA operator.
  - **If left empty**: This step will use default value i.e., "stable".
- `TEST_COLLECT_BASE_DIR`
  - **Definition**: Result directory where are placed test results and logs. This should be set to ARTIFACT_DIR to have results correctly uploaded.
  - **If left empty**: This step will use default value i.e., "data/results".
  
## Custom Images

- `rhba-runner`
  - [Dockerfile](https://github.com/kiegroup/kie-cloud-tests-container/blob/main/Dockerfile)
  - The custom image for this step uses the ubi8/openjdk-11 as it's base. The image should have all of the required dependencies installed to run the tests.