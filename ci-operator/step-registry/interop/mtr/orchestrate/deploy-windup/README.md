# interop-mtr-orchestrate-deploy-windup-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Container Used](#container-used)
- [Requirements](#requirements)
  - [Variables](#variables)
  - [Infrastructure](#infrastructure)

## Purpose

To deploy Windup to the `mtr` Namespace with the `volumeCapacity` set to 5Gi. This step is necessary to execute the interop tests for the MTR operator.

## Process

This script is very simple. It uses `oc` to deploy Windup, the waits 5 minutes to allow Windup to finish deploying before proceeding.

## Container Used

The container used to execute this step is the built-in `cli`image.

## Requirements

### Variables

**NONE**

### Infrastructure

- A provisioned test cluster to target.
  - This cluster should have a `mtr` Namespace with the MTR operator installed on it.
  - Should have enough space to hold a 5Gi volume