# add-mcoqe-robot-to-pull-secret-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To add a "mcoqe" robot account's credentials to the cluster's pull-secret. These creadentials are needed to run MCO OS Layering test cases, since the layered osImage will be stored in the "mcoqe/layering" quay.io repository.

Example of a chain using this step

```
chain:
  as: openshift-e2e-test-mco-qe-longrun
  steps:
  - chain: cucushift-installer-check-cluster-health
  - ref: idp-htpasswd
  - ref: mco-conf-day2-add-mcoqe-robot-to-pull-secret
  - ref: openshift-extended-test-longduration
  - ref: openshift-e2e-test-qe-report
  documentation: |-
    Execute openshift extended MCO e2e tests from QE. It does not execute cucushift test cases.
```

## Process

This script reads the auth info from the secret mounted in /var/run/vault/mcoqe-robot-account/auth, then it merges this information with the cluster's pull-secret info and updates the pull-secret value in the cluster

## Prerequisite(s)

- A provisioned test cluster to target.

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- None
