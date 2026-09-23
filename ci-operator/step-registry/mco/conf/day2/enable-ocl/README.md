# enable-ocl-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To enable the OCL functionality in the cluster. In order to enable the OCL functionality we need to create a MachineOsConfig resource defining the repository where the OCL images will be stored and 3 secrets to push and pull those images.

The repository where the iamges will be stored is: quay.io/mcoqe/layering
The credentials to access this repository are added the the cluster's pull-secret by the mco-conf-day2-add-mcoqe-robot-to-pull-secret step. Hence, we will use a copy of the cluster's pull-secret to configure our MOSCs.

Example of a chain using this step

```
chain:
  as: openshift-e2e-test-mco-qe-longduration
  steps:
  - chain: cucushift-installer-check-cluster-health
  - ref: idp-htpasswd
  - ref: mco-conf-day2-add-mcoqe-robot-to-pull-secret
  - ref: mco-conf-day2-enable-ocl
  - ref: openshift-extended-test-longduration
  - ref: openshift-e2e-test-qe-report
  documentation: |-
    Execute openshift extended MCO e2e tests from QE. It does not execute cucushift test cases.
```

## Process

This scripts creates a MOSC resource for every MCP declared in MCO_CONF_DAY2_OCL_POOLS. These MOSCs will use a copy of the pull-secret to access the registry quay.io/mcoqe/layering

## Prerequisite(s)

-  The cluster's pull-secret should contain the credentials to pull and push from quay.io/mcoqe/layering. These credentials are added by the mco-conf-day2-add-mcoqe-robot-to-pull-secret step.

### Infrastructure

- A provisioned test cluster to target.

### Environment Variables

- MCO_CONF_DAY2_OCL_IMG_EXPIRATION_TIME: space separated list of the MCPs where we want to enable OCL
- MCO_CONF_DAY2_OCL_IMG_EXPIRATION_TIME: expiration time for the created OCL images
