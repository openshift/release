# oadp-s3-create-ref<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->

- [Purpose](#purpose)
- [Process](#process)
- [Prerequisite(s)](#prerequisites)
  - [Infrastructure](#infrastructure)
  - [Environment Variables](#environment-variables)

## Purpose

To create an AWS S3 bucket to be used during OADP test execution.

## Process

This script does the following to ensure a bucket is created for OADP test execution:

1. Sets all required variables to login to the AWS CLI in the pod.
2. Modifies the `$BUCKET_NAME` variable by adding the `$NAMESPACE` variable to the beginning of it. This is only done to avoid any potential naming conflicts.
3. Executes a [script maintained by OADP PQE](https://github.com/oadp-qe/oadp-qe-automation/blob/main/backup-locations/aws-s3/deploy.sh) to deploy the S3 bucket.
4. Copy the `credentials` file created by the script into the `$SHARED_DIR` directory for use in the [`oadp-execute-tests`](../../execute-tests/README.md) ref later.

## Prerequisite(s)

### Infrastructure

- An AWS account that can be used to provision the bucket
  - This account should be defined in the `cluster_profile` value of the configuration file.

### Environment Variables

- `BUCKET_NAME`
  - **Definition**: The name of the AWS S3 bucket to create. The bucket name will actually be `$NAMESPACE-$BUCKET_NAME` to avoid any potential naming conflicts.
  - **If left empty**: A default value of `interopoadp` will be used.