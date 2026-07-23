# mce-must-gather-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

> :warning: **This has only been tested against an environment consisting of a single hub cluster, this may or may not work if their are spoke cluster managed by the hub cluster.**

## Purpose

To gather information for further debugging using the mce must-gather image.

## Process

- Run MCE must-gather
- Saves output to the $ARTIFACT_DIR

## Requirements
- Advanced-cluster-management operator and Multi-cluster-engine are installed on the OCP cluster.

### Infrastructure

- A provisioned OCP test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))

### Environment Variables

- None