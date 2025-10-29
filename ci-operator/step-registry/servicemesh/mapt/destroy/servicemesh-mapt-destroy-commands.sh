#!/bin/bash

# Script to destroy an OpenShift SNC cluster created with MAPT (Multi Architecture Provisioning Tool)
# This script destroys the AWS cluster and cleans up the S3 bucket used for state storage.

set -e

setup() {
  echo "========== Setup =========="
  # Configuration variables
  UNIQUE_PROJECT_NAME=$(cat ${SHARED_DIR}/project_name)
  BUCKET_NAME=$(cat ${SHARED_DIR}/s3_bucket_name)
  echo "Using project name: ${UNIQUE_PROJECT_NAME}"
  echo "Using S3 bucket: ${BUCKET_NAME}"

  # AWS credentials validation
  CRED_FILE=""
  if [ -f "/tmp/secrets/.awscred" ]; then
    CRED_FILE="/tmp/secrets/.awscred"
  elif [ -f "/tmp/secrets/config" ]; then
    CRED_FILE="/tmp/secrets/config"
  else
    echo "Error: AWS credentials file not found (looked for .awscred and config)"
    exit 1
  fi

  echo "Using credentials file: ${CRED_FILE}"
  export AWS_SHARED_CREDENTIALS_FILE="${CRED_FILE}"
  AWS_REGION=${AWS_REGION:-"us-east-1"}
  export AWS_REGION
}

mapt_destroy() {
  echo "========== MAPT Cluster Destruction =========="
  echo "Destroying MAPT cluster with project name: ${UNIQUE_PROJECT_NAME}"
  echo "Using S3 bucket for state storage: ${BUCKET_NAME}"
  mapt aws openshift-snc destroy \
    --project-name ${UNIQUE_PROJECT_NAME} \
    --backed-url "s3://${BUCKET_NAME}" 

  # Clean up S3 bucket only if the deletion was successful
  if [ $? -eq 0 ]; then
    echo "Deleting S3 bucket: ${BUCKET_NAME}"
    aws s3 rb "s3://${BUCKET_NAME}" --force
    echo "S3 bucket ${BUCKET_NAME} deleted"
  else
    echo "Cluster destruction failed. S3 bucket ${BUCKET_NAME} not deleted."
  fi
}

setup
mapt_destroy
echo "Cluster destruction process completed and S3 bucket cleanup completed."
