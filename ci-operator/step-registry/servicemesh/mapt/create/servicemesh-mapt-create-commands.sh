#!/bin/bash

# Script to create an OpenShift SNC cluster using MAPT (Multi Architecture Provisioning Tool)
# This script provisions a spot AWS instance with OpenShift SNC and generates kubeconfig
# for connecting to the cluster. The cluster information is stored in S3 for later destruction.

set -e

# Configuration variables
PROJECT_NAME=${PROJECT_NAME:-"servicemesh"}
TEST_NAME=${TEST_NAME:-"servicemesh-mapt"}
# Created issue https://github.com/redhat-developer/mapt/issues/628 to improve the OCP version selection in the MAPT tool
OCP_VERSION=${OCP_VERSION:-"4.19.12"}
MAPT_TAGS=${MAPT_TAGS:-"ci=true,repo=openshift-servicemesh"}
SPOT=${SPOT:-"true"}
CPU=${CPU:-16}
MEMORY=${MEMORY:-64}
OUTPUT_CONNECTION_DIR=${SHARED_DIR:-"/workspace"}
TIMEOUT=${TIMEOUT:-10m}

# Check that required secret files exist
ls -l /tmp/secrets
if [ ! -f /tmp/secrets/.awscred ]; then
  echo "Error: AWS credentials file not found"
  exit 1
fi

# AWS credentials
CRED_FILE="/tmp/secrets/.awscred"
AWS_ACCESS_KEY_ID=$(awk -v profile="openshift-service-mesh-dev" -v key="aws_access_key_id" '
  $0 ~ "\\["profile"\\]" { in_profile=1; next }
  in_profile && $0 ~ "^\\[" { in_profile=0 }
  in_profile && $1 == key "=" { print $3; exit }
' "$CRED_FILE")
AWS_SECRET_ACCESS_KEY=$(awk -v profile="openshift-service-mesh-dev" -v key="aws_secret_access_key" '
  $0 ~ "\\["profile"\\]" { in_profile=1; next }
  in_profile && $0 ~ "^\\[" { in_profile=0 }
  in_profile && $1 == key "=" { print $3; exit }
' "$CRED_FILE")
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_REGION=${AWS_REGION:-"us-east-1"}
export AWS_REGION

# Create S3 bucket for MAPT state storage
BUCKET_NAME="mapt-${TEST_NAME}-$(date +%s)-$RANDOM$RANDOM"
export BUCKET_NAME
echo "Creating S3 bucket: ${BUCKET_NAME}"
aws s3api create-bucket --bucket ${BUCKET_NAME} --region $AWS_REGION
# Save the bucket name in SHARED_DIR for use in destroy step
echo ${BUCKET_NAME} > ${SHARED_DIR}/bucket_name
echo "S3 bucket ${BUCKET_NAME} created"

# Create pull secret
echo "Checking that pull secret file exists in /tmp/secrets..."

if [ ! -f /tmp/secrets/pull-secret ]; then
  echo "Error: Pull secret file not found"
  exit 1
fi

echo "Pull secret file exists"

# Create the cluster using MAPT
MAPT_COMMAND="mapt aws openshift-snc create \
  --backed-url s3://${BUCKET_NAME} \
  --conn-details-output ${OUTPUT_CONNECTION_DIR} \
  --pull-secret-file /tmp/secrets/pull-secret \
  --project-name ${PROJECT_NAME} \
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

# Verify cluster creation
if [ ! -f "${OUTPUT_CONNECTION_DIR}/kubeconfig" ]; then
  echo "Error: kubeconfig file not found in ${OUTPUT_CONNECTION_DIR}"
  exit 1
fi

# Get oc client
echo "Downloading oc client..."
echo "Installing oc CLI..."
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
tar -xzf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/
sudo chmod +x /usr/local/bin/oc
oc version --client
echo "oc CLI installed successfully"


echo "Cluster created successfully. Kubeconfig is available at ${OUTPUT_CONNECTION_DIR}/kubeconfig"

# Copy kubeconfig to SHARED_DIR for CI-Operator and subsequent steps
cp "${OUTPUT_CONNECTION_DIR}/kubeconfig" "${SHARED_DIR}/kubeconfig"
echo "Kubeconfig copied to ${SHARED_DIR}/kubeconfig for use by subsequent steps"

# Wait for cluster to be ready
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "Waiting for cluster to be ready..."
oc wait --for=condition=Ready nodes --all --timeout=${TIMEOUT}
echo "Cluster is ready."

