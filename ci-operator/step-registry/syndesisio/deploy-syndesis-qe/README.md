# syndesisio-deploy-syndesis-qe-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)

## Purpose

To Create the `syndesis-qe` test runner pod, execute the test suite entrypoint, and archive the test run artifacts.

## Process

This script uses `oc` to create the test runner pod. The entrypoint script handles the creation of the `fuse-online` namespace and operator deployment, using the provided credentials of a user with a `cluster-admin` role. Upon the completion of the test run, a `cli` container is used to copy the test run artifacts for archival.

## Requirements

### Infrastructure

- A provisioned test cluster to target.
    - This cluster should allow the creation of pods in the `default` namespace
    - This cluster should support passing the username and password of a user with the `cluster-admin` role.
    - This cluster should support creating an additional namespace to deploy the `fuse-online` operator.
    - This cluster should support the use of `sudo` in the entrypoint script.

### Environment Variables
- FUSE_ONLINE_NAMESPACE
  - Definition: The namespace in which to deploy the fuse-online operator.
  - If left empty: Will use the `fuse-online` namespace, which will be created if it is not present.