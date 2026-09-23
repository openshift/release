# cloud-maintenance-aws-s3bucket-cleanup

## Table of Contents

- [cloud-maintenance-aws-s3bucket-cleanup](#cloud-maintenance-aws-s3bucket-cleanup)
  - [Table of Contents](#table-of-contents)
  - [Purpose](#purpose)
  - [Process](#process)
  - [Prerequisite(s)](#prerequisites)
    - [Environment Variables](#environment-variables)
    - [Other](#other)

## Purpose

To ensure that any residual S3 buckets created in AWS as part of a test are not left in the AWS account used in the `cluster_profile` value specified in the configuration file that makes use of this ref.

## Process

1. Login to AWS using the credentials provided by the `cluster_profile`
2. Retrieve a list of S3 buckets in the provided AWS account
3. Iterate through those buckets and determine 2 things before deciding to delete the bucket or not:
   1. Is this bucket included in the `EXCLUDE_LIST` environment variable?
      - If yes, the bucket **will not** be deleted
      - If no, the next check will occur -->
   2. Is this bucket older than the value specified in `BUCKET_AGE_HOURS`?
      - If it is older, the bucket **will** be deleted
      - If it is not older, the bucket **will not** be deleted 

## Prerequisite(s)

### Environment Variables

- `BUCKET_AGE_HOURS`
  - **Definition**: The cutoff age for a bucket to be deleted in hours.
  - **If left empty**: A default value of 48 hours is used.
- `EXCLUDE_LIST`
  - **Definition**: A comma separated list of bucket names that you do not want to be deleted, no matter how old they may be.
  - **If left empty**: The ref will consider all buckets in the AWS account as viable candidates for deletion, depending on the value specified in the `BUCKET_AGE_HOURS` variable.

### Other

- The `cluster_profile` for the account you'd like to use this ref on must be defined.