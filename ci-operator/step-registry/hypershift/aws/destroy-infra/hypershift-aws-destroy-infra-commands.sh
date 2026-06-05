#!/bin/bash

set -exuo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

# Check if infra-id file exists
if [[ ! -f "${SHARED_DIR}/infra-id" ]]; then
  echo "WARNING: Infrastructure ID file not found at ${SHARED_DIR}/infra-id"
  echo "Skipping infrastructure cleanup"
  exit 0
fi

INFRA_ID="$(cat ${SHARED_DIR}/infra-id)"
CLUSTER_NAME="$(cat ${SHARED_DIR}/cluster-name 2>/dev/null || echo '')"

echo "$(date) Destroying AWS infrastructure for infrastructure ID: ${INFRA_ID}"
[[ -n "${CLUSTER_NAME}" ]] && echo "Cluster name: ${CLUSTER_NAME}"
echo "Region: ${HC_REGION}"

# Destroy infrastructure using hypershift CLI
/usr/bin/hypershift destroy infra aws \
  --infra-id "${INFRA_ID}" \
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --region "${HC_REGION}"

echo "$(date) AWS infrastructure destroyed successfully"

# Clean up SHARED_DIR files
rm -f "${SHARED_DIR}/aws_infra_output.json"
rm -f "${SHARED_DIR}/aws_iam_output.json"
rm -f "${SHARED_DIR}/infra-id"

echo "Infrastructure cleanup completed"
