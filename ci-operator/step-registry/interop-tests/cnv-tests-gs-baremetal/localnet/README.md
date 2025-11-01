# interop-tests-cnv-tests-gs-baremetal-localnet<!-- omit from toc -->

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

To execute OpenShift Virtualization networking tests on a bare-metal cluster configured for Goldman Sachs. All XML results will be saved into `"$ARTIFACT_DIR"`.

## Process

The script performs the following to run Openshift Virtualization networking tests on Goldman Sachs bare-metal cluster:


1. Set KUBECONFIG to `/app/.kube/config`
2. Run `tests/network/localnet/test_default_bridge.py` with specificed environment variables.
3. Move xmls to `${ARTIFACT_DIR}/junit_*.xml`.


### Cluster Setup: `external-cluster`

Please see the [`external-cluster`](https://steps.ci.openshift.org/workflow/external-cluster) documentation for more information on this workflow.

## Prerequisite(s)

### Infrastructure

OCP Test Cluster on Bare Metal with Goldman Sachs HW configuration.

### Environment Variables

  - `BW_PATH`
    - **Definition:** Bitwarden directory
    - **If left empty:** default: `"/bw"`
  - `BREW_IMAGE_REGISTRY_USERNAME`
      - **Definition:**
      - **If left empty:** default: `/var/run/cnv-ci-brew-pull-secret/token`
  -  `BREW_IMAGE_REGISTRY_TOKEN_PATH`
      - **Definition:**
      - **If left empty:** default: `/var/run/cnv-ci-brew-pull-secret/token`
  - `KUBEVIRT_RELEASE`
      - **Definition:**
      - **If left empty:** default: `v0.59.0-alpha.0`
  - `ARTIFACT_DIR`
    - **Definition:**
    - **If left empty:** default: `/tmp/artifacts`
  - `TARGET_NAMESPACE`
      - **Definition:**
      - **If left empty:** default: `openshift-cnv`

### Custom Images
 - [Dockerfile](https://github.com/RedHatQE/openshift-virtualization-tests/blob/main/Dockerfile)