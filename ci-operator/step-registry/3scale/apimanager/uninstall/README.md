# 3scale-apimanager-uninstall-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisite--s-)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To uninstall 3scale API Manager in a specified namespace.

## Process

This script does the following to uninstall apimanager:
1. Sets all the required variables to login to the AWS CLI in the pod.
2. Run `deploy remove` command to delete API Manager and S3 bucket.

## Prerequisite(s)

### Infrastructure

- An AWS account that can be used to delete the S3 bucket
  - This account should be defined in the `cluster_profile` value of the configuration file.
- A provisioned test cluster to target.
  - This cluster should have a 3scale operator installed in a namespace that matches $DEPL_PROJECT_NAME. 

### Environment Variables

- `AWS_REGION`
  - **Definition**: AWS region where the bucket will be created..
  - **If left empty**: This step will fail
- `DEPL_BUCKET_NAME`
  - **Definition**: Name of S3 bucket created for 3scale.
  - **If left empty**: This step will fail
- `DEPL_PROJECT_NAME`
  - **Definition**: Namespace where the 3scale will be deployed. This should match with the namespace where 3scale operator is installed.
  - **If left empty**: This step will fail
