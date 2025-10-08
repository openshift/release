#!/bin/bash

# Script to destroy an OpenShift SNC cluster created with MAPT (Multi Architecture Provisioning Tool)
# This script destroys the AWS cluster and cleans up the S3 bucket used for state storage.

set -e

# Configuration variables
PROJECT_NAME=${PROJECT_NAME:-"servicemesh"}
BUCKET_NAME=$(cat ${SHARED_DIR}/bucket_name)
echo "Using S3 bucket: ${BUCKET_NAME}"

# AWS credentials
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_REGION=${AWS_REGION:-"us-east-1"}
export AWS_REGION


# Destroy the cluster using MAPT
mapt aws openshift-snc destroy \
  --project-name ${PROJECT_NAME} \
  --backed-url "s3://${BUCKET_NAME}" 

# Clean up S3 bucket only if the deletion was successful
if [ $? -eq 0 ]; then
  echo "Deleting S3 bucket: ${BUCKET_NAME}"
  aws s3api delete-bucket --bucket ${BUCKET_NAME} --region $AWS_REGION
  echo "S3 bucket ${BUCKET_NAME} deleted"
else
  echo "Cluster destruction failed. S3 bucket ${BUCKET_NAME} not deleted."
fi

