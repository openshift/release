# gs-baremetal-localnet-test<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Setup: `external-cluster`](#cluster-setup-external-cluster)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [RedHatQE/openshift-virtualization-tests/network/localnet/](https://github.com/RedHatQE/openshift-virtualization-tests/tree/main/tests/network/localnet)

## Purpose

To execute OpenShift Virtualization network tests on a bare-metal cluster configured for Goldman Sachs. All XML results will be saved into `"$ARTIFACT_DIR"`.

## Process

The script performs the following to run Openshift Virtualization `localnet` network tests on Goldman Sachs bare-metal cluster:

  - Run `tests/network/localnet/test_default_bridge.py` with specificed environment variables.


### Cluster Setup: `external-cluster`

Please see the [`external-cluster`](https://steps.ci.openshift.org/workflow/external-cluster) documentation for more information on this workflow.

## Prerequisite(s)

### Infrastructure

OCP Test Cluster on Bare Metal with Goldman Sachs HW configuration.

### Environment Variables

Refer to variables defined in [gs-baremetal-localnet-test-ref.yaml](./gs-baremetal-localnet-test-ref.yaml).

### Custom Images
 - [Dockerfile](https://github.com/RedHatQE/openshift-virtualization-tests/blob/main/Dockerfile)