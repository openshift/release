# acm-fetch-managed-clusters-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To gather information about the managed clusters that are created as a result of the clc-test-create-ref.

## Process

- Set two dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/fetch_clusters_commands.sh) that does some additional config and ultimately runs a python script ([generate_managedclusters_data.py](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/generate_managedclusters_data.py)) to fetch information about the managed clusters.

## Requirements


### Infrastructure

- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-tests-clc-create-commands.sh](../tests/clc-create/acm-tests-clc-create-commands.sh) needs to successfully have run prior to this running. This is what creates the managed clusters that are being used to gather data from.

### Environment Variables

- Please see [acm-fetch-managed-clusters-ref.yaml](acm-fetch-managed-clusters-ref.yaml) env section.