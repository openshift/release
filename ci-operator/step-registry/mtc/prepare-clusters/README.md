# mtc-prepare-clusters-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
- [Custom Image - `mtc-interop`](#custom-image---mtc-interop)

## Purpose

Used to prepare the "source" and "target" clusters for the MTC interoperability tests. This ref will execute Ansible playbooks to install MTC on both clusters and deploy the required resources on the clusters prior to test execution.

## Process

1. Extract the `clusters_data.tar.gz` archive, which holds the information for both test clusters.
2. Execute the `install-mtc.yml` Ansible playbook to install MTC. Must be executed for both the "target" and "source" clusters.
3. Copy the `oc` binary from the `cli` image to `/usr/bin/oc` and use it to login to the "source" cluster.
4. Retrieve the exposed registry path for the "source" cluster, this is used in the next step.
5. Execute the `config_mtc.yml` Ansible playbook to configure both the "source" and "target" clusters prior to test execution.

## Prerequisite(s)

### Infrastructure

- Two provisioned clusters, a "source" and a "target" cluster.
  - "source" cluster should be 1 OCP release being the "target" cluster. For example: if we are running tests for the un-released 4.14 version of OCP, the "source" cluster should be version 4.13 and the "target" cluster should be version 4.13.

## Custom Image - `mtc-interop`

- [Dockerfile](https://github.com/mtc-qe/mtc-interop/blob/master/Dockerfile)

This image is used to the the [`mtc-prepare-clusters` ref](../../../step-registry/mtc/prepare-clusters/README.md). It contains the [mtc-qe/mtc-interop](https://github.com/mtc-qe/mtc-interop) repository and all dependencies required to execute the Ansible playbooks to prepare the two clusters used in this scenario.