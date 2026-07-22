#!/bin/bash
set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

SOURCE_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
SOURCE_MAJOR=$(echo "${SOURCE_VERSION}" | cut -d. -f1)

TARGET_VERSION=$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" \
    --output=json 2>/dev/null | jq -r '.metadata.version') || {
    echo "WARNING: could not determine target version, skipping patch."
    exit 0
}
TARGET_MAJOR=$(echo "${TARGET_VERSION}" | cut -d. -f1)

if [[ "${SOURCE_MAJOR}" != "4" || "${TARGET_MAJOR}" != "5" ]]; then
    echo "Not a 4.x to 5.x upgrade (${SOURCE_VERSION} to ${TARGET_VERSION}), skipping."
    exit 0
fi

echo "Detected 4.x to 5.x upgrade (${SOURCE_VERSION} to ${TARGET_VERSION}), patching master IAM role."

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
MASTER_ROLE="${INFRA_ID}-master-role"
POLICY_NAME="${INFRA_ID}-master-upgrade-policy"

echo "Adding inline policy ${POLICY_NAME} to role: ${MASTER_ROLE}"

aws --region "${REGION}" iam put-role-policy \
  --role-name "${MASTER_ROLE}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "elasticloadbalancing:SetSecurityGroups"
        ],
        "Resource": "*"
      }
    ]
  }'

echo "Successfully added inline policy ${POLICY_NAME} to ${MASTER_ROLE}"
