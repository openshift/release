# syndesisio-setup-syndesis-qe-env-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
    - [Infrastructure](#infrastructure)
    - [Environment Variables](#environment-variables)

## Purpose

To prepare the test cluster environment for deployment of the `syndesis-qe` test runner.

## Process

This script uses `oc` to switch to the default project and add the `cluster-admin` role to the kubeadmin user, as required by the `syndesis-qe` test runner.

## Requirements

### Infrastructure

- A provisioned test cluster to target.
    - This cluster should allow the creation of pods in the `default` namespace
    - This cluster should support adding the `cluster-admin` role to the provisioned `kubeadmin` user 

### Environment Variables