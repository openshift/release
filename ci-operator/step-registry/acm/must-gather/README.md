# acm-fetch-managed-clusters-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To gather information for further debugging using the acm must-gather images.

## Process

- Run ACM must-gather
- Run MCE must-gather
- Saves both outputs to the $ARTIFACT_DIR

## Requirements
- Advanced-cluster-management operator and Multi-cluster-engine are installed on the OCP cluster.

### Infrastructure

- A provisioned OCP test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))

### Environment Variables

- None