# mtr-deploy-windup-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To deploy Windup in a specified namespace with a specified volume capacity. This step is necessary to execute the interop tests for the MTR operator.

## Process

This script is very simple. It uses `oc` to deploy Windup, the waits 5 minutes to allow Windup to finish deploying before proceeding.

## Container Used

The container used to execute this step is the built-in `cli`image.

## Requirements

### Variables

- `WINDUP_NAMESPACE`
  - **Definition**: Namespace to deploy Windup in.
  - **If left empty**: Will use the "mtr" namespace.
- `WINDUP_VOLUME_CAP`
  - **Definition**: Windup volume capacity.
  - **If left empty**: Will use a "5Gi" volume capacity.

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a namespace that matches $WINDUP_NAMESPACE or the default namespace of "mtr"
  - This cluster should have enough space to hold a volume the size of $WINDUP_VOLUME_CAP or the default of "5Gi"