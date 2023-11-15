# data-grid-prepare-cluster-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)

## Purpose

To prepare a new cluster for the Data Grid operator integration tests. This step creates some namespaces and updates some monitoring privileges required prior to installing the operator and starting the tests.

## Process

1. Creates the `dg-integration` and `xtf-builds` namespaces.
2. Enables cluster monitoring and gives permissions to the `system:admin` user.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
