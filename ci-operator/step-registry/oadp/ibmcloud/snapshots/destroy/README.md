# oadp-ibmcloud-snapshots-destroy-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To destroy an IBMCLOUD VPC snapshots created during OADP test execution.

## Process

This script does the following to ensure the bucket created for OADP test execution is destroyed:

1. Login IBMCLOUD resource group
2. Obtain list of VPC snapshots.
3. Obtain source volume.
4. Delete snapshots by source volume

## Prerequisite(s)

### Infrastructure

- An IBMCLOUD account that can be used to provision
  - This account should be defined in the `cluster_profile` value of the configuration file.

### Environment Variables

