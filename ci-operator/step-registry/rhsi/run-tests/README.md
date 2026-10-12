# rhsi-run-tests-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)
    - [Custom Images](#custom-images))

## Purpose

To setup, execute the test suite entrypoint, and archive the test run artifacts.

## Process

This script executes the entrypoint script, handles the creation of the `service-interconnect` namespace and operator deployment, using the provided credentials of a user with a `cluster-admin` role. Upon the completion of the test run the test run artifacts are copied for archival.

## Requirements

### Infrastructure

- A provisioned test cluster to target.
    - This cluster should have a user named `admin` with the `cluster-admin` role.
    - This cluster should support creating additional namespaces to deploy the `service-interconnect` operator.

### Environment Variables

- `KUBECONFIG`
  - **Definition**: Path and name of kubeconfig file of cluster.
  - **If left empty**: This step will fail

### Custom Images

- `rhsi-test-runner`
    - [Image](http://quay.io/rhpit/interop-tests)
    - The custom image for this step uses image from the above image location as its base with updated groups and permissions to run in openshift.
