# mtr-execute-interop-ui-tests-chain<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Variables](#variables)
  - [~~Credentials~~](#credentials)

## Purpose

To retrieve the test cluster's host URL and execute the interop tests in the [windup/windup-ui-tests](https://github.com/windup/windup-ui-tests) repository using that URL.

## Process

1. [mtr-retrieve-cluster-url](../retrieve-cluster-url/README.md)
2. [mtr-execute-ui-tests](../execute-ui-tests/README.md)

## Requirements

### Infrastructure

- A provisioned test cluster to target.
  - Should have a `mtr` namespace/project with:
    - [The `mtr-operator` installed](../install/README.md).
    - [Windup deployed](../deploy-windup/README.md).

### Variables

- `CYPRESS_INCLUDE_TAGS`
  - **Definition**: Tag you'd like to use to execute Cypress. Should be `interop` for this chain.
  - **If left empty**: It will use 'interop' as the default value.

### ~~Credentials~~