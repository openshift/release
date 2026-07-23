# acm-mch-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create a MultiClusterHub (MCH) in a specified namespace after ACM operator install. This step is necessary to execute tests for ACM.

## Process

It uses `oc apply` to create a MCH, then continuously checks if the deployment is complete and ready. If it isn't ready within 15 minutes this step will fail.

## Requirements


### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a namespace that matches $MCH_NAMESPACE or the default namespace for the "advanced-cluster-management" operator.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).

### Environment Variables

- Please see [acm-mch-ref.yaml](acm-mch-ref.yaml) env section.