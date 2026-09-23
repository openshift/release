# jboss-fuse-run-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
- [Custom Images](#custom-images)

## Purpose

To execute multiple instances (PODs) of Fuse On Openshift XpaaS-QE test-suite. All XML results will be saved into "$ARTIFACT_DIR".

## Process

This script does the following to run Fuse On Openshift interop tests:
1. Create PODs for each deployent config related to a single test class
2. Check the PODs status periodically
2. Copy xmls file to `${ARTIFACT_DIR}/junit_*.xml`.
3. Copy logs file to `${ARTIFACT_DIR}`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.


## Custom Images

- `xpaas-qe`
  - [Dockerfile](https://github.com/jboss-fuse/fuse-xpaas-qe-container/blob/main/Dockerfile)
    The custom image for this step is related to xpaas-qe test-suite installation and run. All the required dependencies are already included in the container.