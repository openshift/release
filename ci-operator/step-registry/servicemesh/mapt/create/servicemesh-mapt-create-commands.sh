#!/bin/bash

# Script to create an OpenShift SNC cluster using MAPT (Multi Architecture Provisioning Tool)
# This script provisions a spot AWS instance with OpenShift SNC and generates kubeconfig
# for connecting to the cluster. The cluster information is stored in S3 for later destruction.

set -e

# Configuration variables
PROJECT=${PROJECT:-"servicemesh"}
TEST_NAME=${TEST_NAME:-"servicemesh-mapt"}
# Created issue https://github.com/redhat-developer/mapt/issues/628 to improve the OCP version selection in the MAPT tool
OCP_VERSION=${OCP_VERSION:-"4.20.0"}
MAPT_TAGS=${MAPT_TAGS:-"ci=true,repo=openshift-servicemesh"}
MAPT_IMAGE=${MAPT_IMAGE:-"quay.io/redhat-developer/mapt:v0.9.9"}
SPOT=${SPOT:-"true"}
CPU=${CPU:-16}
MEMORY=${MEMORY:-64}
# Issue created for timeout handling: https://github.com/redhat-developer/mapt/issues/649.
TIMEOUT=${TIMEOUT:-10m}

# Setting all the variables for MAPT
export CLUSTER_NAME="${PROJECT}-mapt-$(date +%s)"
export CLUSTER_VERSION="${OCP_VERSION}"
export CLUSTER_CPUS="${CPU}"
export CLUSTER_MEMORY="${MEMORY}"
export CLUSTER_SPOT="${SPOT}"
export PULL_SECRET_FILE="/tmp/secrets/pull-secret"
export CLUSTER_TAGS="${MAPT_TAGS}"
export S3_BUCKET_PREFIX="mapt-cluster"
export CONTAINER_ENGINE="podman"
export LOG_LEVEL="verbose"
export CI=true
export BACKED_URL_TYPE="s3"

# Print configuration
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Cluster Version: ${CLUSTER_VERSION}"
echo "Cluster CPUs: ${CLUSTER_CPUS}"
echo "Cluster Memory: ${CLUSTER_MEMORY} GB"
echo "Using Spot Instances: ${CLUSTER_SPOT}"
echo "S3 Bucket Prefix: ${S3_BUCKET_PREFIX}"
echo "MAPT Tags: ${CLUSTER_TAGS}"
OUTPUT_CONNECTION_DIR="${SHARED_DIR}/mapt-connection"
mkdir -p "${OUTPUT_CONNECTION_DIR}"
echo "Output Connection Directory: ${OUTPUT_CONNECTION_DIR}"

# Save the CLUSTER_NAME in SHARED_DIR for later use
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/mapt_cluster_name"

# DEBUG: Check the content of the SHARED_DIR
echo "Contents of SHARED_DIR (${SHARED_DIR}):"
ls -la ${SHARED_DIR}

# DEBUG: Check that required secret files exist
echo "Contents of secrets directory:"
ls -la /tmp/secrets/

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

# Check that pull secret file exists
echo "Checking that pull secret file exists in /tmp/secrets..."
if [ ! -f /tmp/secrets/pull-secret ]; then
  echo "Error: Pull secret file not found"
  exit 1
fi
echo "Pull secret file exists"

# Get mapt script from ci-utils ossm repo
echo "Getting MAPT script..."
MAPT_SCRIPT_URL="https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/main/apt_cluster/create_mapt_cluster.sh"
curl -o /tmp/create_mapt_cluster.sh ${MAPT_SCRIPT_URL}
if [ $? -ne 0 ]; then
  echo "Error: Failed to download MAPT script from ${MAPT_SCRIPT_URL}"
  exit 1
fi
chmod +x /tmp/create_mapt_cluster.sh

# Create the cluster using MAPT script
echo "Creating OpenShift SNC cluster using MAPT..."
/tmp/create_mapt_cluster.sh --create-only --verbose

# Verify cluster creation
if [ ! -f "${OUTPUT_CONNECTION_DIR}/kubeconfig" ]; then
  echo "Error: kubeconfig file not found in ${OUTPUT_CONNECTION_DIR}"
  exit 1
fi

echo "Cluster created successfully. Kubeconfig is available at ${OUTPUT_CONNECTION_DIR}/kubeconfig"

# Wait for cluster to be ready
export KUBECONFIG="${OUTPUT_CONNECTION_DIR}/kubeconfig"
echo "Waiting for cluster to be ready..."
oc wait --for=condition=Ready nodes --all --timeout=${TIMEOUT}
echo "Cluster is ready."
