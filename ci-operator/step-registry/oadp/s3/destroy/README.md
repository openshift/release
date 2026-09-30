# oadp-s3-destroy-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To destroy an AWS S3 bucket created for use during OADP test execution.

## Process

This script does the following to ensure the bucket created for OADP test execution is destroyed:

1. Sets all required variables to login to the AWS CLI in the pod.
2. Modifies the `$BUCKET_NAME` variable by adding the `$NAMESPACE` variable to the beginning of it. This is only done to avoid any potential naming conflicts.
3. Executes a [script maintained by OADP PQE](https://github.com/oadp-qe/oadp-qe-automation/blob/main/backup-locations/aws-s3/destroy.sh) to destroy the S3 bucket.

## Prerequisite(s)

### Infrastructure

- An AWS account that can be used to provision the bucket
  - This account should be defined in the `cluster_profile` value of the configuration file.

### Environment Variables

- `BUCKET_NAME`
  - **Definition**: The name of the AWS S3 bucket to create. The bucket name will actually be `$NAMESPACE-$BUCKET_NAME` to avoid any potential naming conflicts.
  - **If left empty**: A default value of `interopoadp` will be used.