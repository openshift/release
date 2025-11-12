# gs-baremetal-localnet-test<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [General Information](#general-information)
- [Purpose](#purpose)
- [Process](#process)
  - [Cluster Provisioning and Deprovisioning: `external-cluster`](#cluster-provisioning-and-deprovisioning-external-cluster)
  - [Test Setup, Execution, and Reporting Results: `gs-baremetal-localnet-test`](#test-setup-execution-and-reporting-results-gs-baremetal-localnet-test)
- [Prerequisite(s)](#prerequisites)
  - [Environment Variables](#environment-variables)
  - [Custom Images](#custom-images)

## General Information

- **Repository**: [RedHatQE/openshift-virtualization-tests/network/localnet/](https://github.com/RedHatQE/openshift-virtualization-tests/tree/main/tests/network/localnet)

## Purpose

To execute OpenShift Virtualization network tests on a bare-metal cluster configured for Goldman Sachs. All XML results will be saved into `"$ARTIFACT_DIR"`.

## Process

### Cluster Provisioning and Deprovisioning: `external-cluster`

The [`external-cluster`](../../../step-registry/gs-baremetal/localnet-test/README.md) workflow imports KUBECONFIG file of a cluster that was deployed outside CI Operator.

### Test Setup, Execution, and Reporting Results: `gs-baremetal-localnet-test`

Following the test cluster setup, the following steps are executed:
- [`gs-baremetal-localnet-test`](../../../step-registry/gs-baremetal/localnet-test/README.md)

## Prerequisite(s)

### Environment Variables

  - OCP_VERSION: The version of OpenShift Container Platform being tested.

### Custom Images
 - [Dockerfile](https://github.com/RedHatQE/openshift-virtualization-tests/blob/main/Dockerfile)