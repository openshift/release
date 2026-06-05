#!/bin/bash

set -exuo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com

HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
fi

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
INFRA_ID="${CLUSTER_NAME}"

echo "$(date) Creating AWS infrastructure for HyperShift cluster ${CLUSTER_NAME}"
echo "Region: ${HC_REGION}"
echo "Base domain: ${DOMAIN}"
echo "Infrastructure ID: ${INFRA_ID}"

# Create AWS infrastructure separately
/usr/bin/hypershift create infra aws \
  --name "${CLUSTER_NAME}" \
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --base-domain "${DOMAIN}" \
  --infra-id "${INFRA_ID}" \
  --region "${HC_REGION}" \
  --output-file "${SHARED_DIR}/aws_infra_output.json"

# Save infra-id for use by IAM and cluster creation steps
echo "${INFRA_ID}" > "${SHARED_DIR}/infra-id"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

echo "$(date) AWS infrastructure created successfully"
echo "Infrastructure resources saved to ${SHARED_DIR}/aws_infra_output.json"

# Display created infrastructure (for debugging)
if [[ -f "${SHARED_DIR}/aws_infra_output.json" ]]; then
  echo "Created infrastructure:"
  cat "${SHARED_DIR}/aws_infra_output.json"
fi
