#!/bin/bash
set -o nounset
set -o pipefail

# Read AWS credentials without xtrace (SC2155: declare separately)
set +x
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY
set -x

# Detect actual cluster region
AWS_REGION=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "${AWS_REGION}")
export AWS_DEFAULT_REGION="${AWS_REGION}"
echo "Teardown: region=${AWS_REGION}"

INSTANCE_ID_FILE="${SHARED_DIR}/ext_instance_id"
if [ ! -f "${INSTANCE_ID_FILE}" ]; then
  echo "No external instance ID file found at ${INSTANCE_ID_FILE} — nothing to teardown"
  exit 0
fi

EXT_INSTANCE_ID=$(cat "${INSTANCE_ID_FILE}")
if [ -z "${EXT_INSTANCE_ID}" ]; then
  echo "Instance ID file empty — nothing to teardown"
  exit 0
fi

echo "Terminating external instance ${EXT_INSTANCE_ID}..."
aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${EXT_INSTANCE_ID}" || true

echo "Waiting for instance ${EXT_INSTANCE_ID} to terminate (max 5 min)..."
aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids "${EXT_INSTANCE_ID}" || true

echo "Teardown complete for instance ${EXT_INSTANCE_ID}"
