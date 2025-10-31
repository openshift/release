#!/bin/bash

# Script to create an OpenShift SNC cluster using MAPT (Multi Architecture Provisioning Tool)
# This script provisions a spot AWS instance with OpenShift SNC and generates kubeconfig
# for connecting to the cluster. The cluster information is stored in S3 for later destruction.
# Known issues:
# - OCP versions need to be defined with Major.Minor.Patch, e.g., 4.20.0. Opened an issue to improve and being able to set latest: https://github.com/redhat-developer/mapt/issues/628
# - Timeout for cluster automatic deletion is not working properly, issue tracking: https://github.com/redhat-developer/mapt/issues/649


set -e

# ===== Configuration variables =====
PROJECT_NAME=${PROJECT_NAME:-"servicemesh"}
UNIQUE_PROJECT_NAME=$PROJECT_NAME-$(date +%s)-$RANDOM$RANDOM
TEST_NAME=${TEST_NAME:-"servicemesh-mapt"}
OCP_VERSION=${OCP_VERSION:-"4.20.0"}
MAPT_TAGS=${MAPT_TAGS:-"ci=true,repo=openshift-servicemesh"}
SPOT=${SPOT:-"true"}
SPOT_INCREASE_RATIO=${SPOT_INCREASE_RATIO:-"40"}
CPU=${CPU:-16}
MEMORY=${MEMORY:-64}
TIMEOUT=${TIMEOUT:-10m}

presetups() {
  echo "========== Presetups =========="
  # Write in the SHARED_DIR the UNIQUE_PROJECT_NAME for use in destroy step
  echo "Project name for MAPT cluster: ${UNIQUE_PROJECT_NAME}"
  echo ${UNIQUE_PROJECT_NAME} > ${SHARED_DIR}/project_name

  # Check for pull-secret file
  if [ ! -f /tmp/secrets/pull-secret ]; then
    echo "Error: Pull secret file not found"
    exit 1
  fi

  # DEBUG: Check that required secret files exist
  echo "Contents of secrets directory:"
  ls -la /tmp/secrets/

  # Create output directory for MAPT connection details
  OUTPUT_CONNECTION_DIR="${SHARED_DIR}/mapt-connection"
  mkdir -p "${OUTPUT_CONNECTION_DIR}"
  echo "Output connection directory: ${OUTPUT_CONNECTION_DIR}"
}

aws_validation() {
  echo "========== AWS Validation =========="
  echo "Validating AWS credentials..."
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


s3_bucket_creation() {
  echo "========== S3 Bucket Creation =========="
  # Create S3 bucket for MAPT state storage
  BUCKET_NAME="mapt-${TEST_NAME}-$(date +%s)-$RANDOM$RANDOM"
  export BUCKET_NAME
  echo "Creating S3 bucket: ${BUCKET_NAME}"
  aws s3api create-bucket --bucket ${BUCKET_NAME} --region $AWS_REGION
  # Save the bucket name in SHARED_DIR for use in destroy step
  echo ${BUCKET_NAME} > ${SHARED_DIR}/bucket_name
  echo "S3 bucket ${BUCKET_NAME} created"

  # Write the bucket name to a file for deletion reference
  echo "S3 Bucket Name: ${BUCKET_NAME}" > ${SHARED_DIR}/s3_bucket_name
  echo "S3 bucket name saved to ${SHARED_DIR}/s3_bucket_name"
}

mapt_cluster_creation() {
  echo "========== MAPT Cluster Creation =========="
  # Create the cluster using MAPT
  MAPT_COMMAND="mapt aws openshift-snc create \
    --backed-url s3://${BUCKET_NAME} \
    --conn-details-output ${OUTPUT_CONNECTION_DIR} \
    --pull-secret-file /tmp/secrets/pull-secret \
    --project-name ${UNIQUE_PROJECT_NAME} \
    --tags project=crc,${MAPT_TAGS} \
    --version ${OCP_VERSION} \
    --cpus ${CPU} \
    --memory ${MEMORY}"

  # Add --spot option if SPOT is set to true
  if [ "${SPOT}" = "true" ]; then
    MAPT_COMMAND="${MAPT_COMMAND} --spot"
  fi

  echo "Executing: ${MAPT_COMMAND}"
  eval ${MAPT_COMMAND}

  echo "Cluster creation command executed"
  # Verify cluster creation
  if [ ! -f "${OUTPUT_CONNECTION_DIR}/kubeconfig" ]; then
    echo "Error: kubeconfig file not found in ${OUTPUT_CONNECTION_DIR}"
    exit 1
  fi
  echo "Kubeconfig file found: ${OUTPUT_CONNECTION_DIR}/kubeconfig"
}

# Verify SHARED_DIR exists
if [ -z "${SHARED_DIR}" ]; then
  echo "Error: SHARED_DIR is not defined"
  exit 1
fi

presetups
aws_validation
s3_bucket_creation
mapt_cluster_creation

# TODO: Add verification of cluster readiness (e.g., wait for nodes to be ready). Meanwhile will need to rely on testing steps to verify cluster usability.
echo "Cluster created successfully. Kubeconfig is available at ${OUTPUT_CONNECTION_DIR}/kubeconfig"
