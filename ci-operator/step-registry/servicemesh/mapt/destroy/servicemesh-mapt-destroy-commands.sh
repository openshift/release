#!/bin/bash

# Script to destroy an OpenShift SNC cluster created with MAPT (Multi Architecture Provisioning Tool)
# This script destroys the AWS cluster and cleans up the S3 bucket used for state storage.

set -e

# Configuration variables
echo "Getting CLUSTER_NAME from SHARED_DIR..."
CLUSTER_NAME=$(cat ${SHARED_DIR}/mapt_cluster_name)
MAPT_IMAGE=${MAPT_IMAGE:-"quay.io/redhat-developer/mapt:v0.9.9"}


# Look for AWS credentials file - check both possible names
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

# Set AWS credentials environment variables
echo "Parsing AWS credentials from ${CRED_FILE}..."
set +x   # disable tracing to avoid leaking sensitive vars
AWS_ACCESS_KEY_ID=$(grep 'aws_access_key_id' "${CRED_FILE}" | awk -F ' = ' '{print $2}' | tr -d '\r')
AWS_SECRET_ACCESS_KEY=$(grep 'aws_secret_access_key' "${CRED_FILE}" | awk -F ' = ' '{print $2}' | tr -d '\r')
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
set -x   # re-enable tracing

AWS_REGION=${AWS_REGION:-"us-east-1"}
export AWS_REGION


# Get mapt script from ci-utils ossm repo
echo "Getting MAPT script..."
MAPT_SCRIPT_URL="https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/main/apt_cluster/create_mapt_cluster.sh"
curl -o /tmp/create_mapt_cluster.sh ${MAPT_SCRIPT_URL}
if [ $? -ne 0 ]; then
  echo "Error: Failed to download MAPT script from ${MAPT_SCRIPT_URL}"
  exit 1
fi
chmod +x /tmp/create_mapt_cluster.sh

# Destroy the cluster using MAPT script
echo "Destroying OpenShift SNC cluster using MAPT..."
/tmp/create_mapt_cluster.sh --delete-only --verbose

echo "Cluster ${CLUSTER_NAME} destroyed successfully."
