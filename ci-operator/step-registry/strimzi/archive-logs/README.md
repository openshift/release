# strimzi-archive-logs-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
    - [Infrastructure](#infrastructure)

## Purpose

All XML results from Strimzi test suite will be copied into `$ARTIFACT_DIR/junit_*.xml`.

## Process

1. Copies the XML files from result dir to `$ARTIFACT_DIR/junit_*.xml`.

## Prerequisite(s)

### Infrastructure

- A provisioned test cluster to target.
- `KUBECONFIG` env variable set. This is done automatically by prow.
