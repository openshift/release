#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"

ROUTE53_HOSTED_ZONE_NAME="${CLUSTER_NAME}.${BASE_DOMAIN}"
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
CALLER_REFERENCE_STR=$ROUTE53_HOSTED_ZONE_NAME

echo -e "creating route53 hosted zone: ${ROUTE53_HOSTED_ZONE_NAME}"
HOSTED_ZONE_CREATION=$(aws --region "$REGION" route53 create-hosted-zone --name "${ROUTE53_HOSTED_ZONE_NAME}" --vpc VPCRegion="${REGION}",VPCId="${VPC_ID}" --caller-reference "${CALLER_REFERENCE_STR}")

HOSTED_ZONE_ID="$(echo "${HOSTED_ZONE_CREATION}" | jq -r '.HostedZone.Id' | awk -F / '{printf $3}')"
# save hosted zone information to ${SHARED_DIR} for deprovision step
echo "${HOSTED_ZONE_ID}" > "${SHARED_DIR}/hosted_zone_id"
CHANGE_ID="$(echo "${HOSTED_ZONE_CREATION}" | jq -r '.ChangeInfo.Id' | awk -F / '{printf $3}')"

aws --region "${REGION}" route53 wait resource-record-sets-changed --id "${CHANGE_ID}" &
wait "$!"
echo "Hosted zone ${HOSTED_ZONE_ID} successfully created."
