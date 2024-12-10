#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json

if [ -z "${AWS_PROFILE:-}" ]; then
  unset AWS_PROFILE
fi 

TMP_DIR=$(mktemp -d)

if [ -f "${SHARED_DIR}/CLUSTER_NAME" ]; then
  CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
else
  HASH="$(echo -n "$PROW_JOB_ID"|sha256sum)"
  CLUSTER_NAME=${HASH:0:20}
fi

echo "Getting the hosted zone ID for domain: ${BASE_DOMAIN}"
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${BASE_DOMAIN}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${BASE_DOMAIN}.\`].Id" \
            --output text)"

cat > "${SHARED_DIR}/dns_up.json" <<EOF
{
  "Comment": "Upsert records for ${CLUSTER_NAME}.${BASE_DOMAIN}",
  "Changes": []
}
EOF

if [ -f "${SHARED_DIR}/API_IP" ]; then
  API_IP=$(<"${SHARED_DIR}"/API_IP)
  if [[ "${API_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    API_RECORD_TYPE="A"
  else
    API_RECORD_TYPE="AAAA"
  fi
  echo "Creating API DNS $API_RECORD_TYPE record for $CLUSTER_NAME.$BASE_DOMAIN"
  jq '.Changes += [{"Action": "UPSERT", "ResourceRecordSet": {"Name": "api.'${CLUSTER_NAME}'.'${BASE_DOMAIN}'.", "Type": "'${API_RECORD_TYPE}'", "TTL": 300, "ResourceRecords": [{"Value": "'${API_IP}'"}]}}]' "${SHARED_DIR}/dns_up.json" > "${TMP_DIR}/dns_api.json"
  cp "${TMP_DIR}/dns_api.json" "${SHARED_DIR}/dns_up.json"
fi

if [ -f "${SHARED_DIR}/INGRESS_IP" ]; then
  INGRESS_IP=$(<"${SHARED_DIR}"/INGRESS_IP)
  if [[ "${INGRESS_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    INGRESS_RECORD_TYPE="A"
  else
    INGRESS_RECORD_TYPE="AAAA"
  fi
  echo "Creating INGRESS DNS $INGRESS_RECORD_TYPE record for $CLUSTER_NAME.$BASE_DOMAIN"
  jq '.Changes += [{"Action": "UPSERT", "ResourceRecordSet": {"Name": "*.apps.'${CLUSTER_NAME}'.'${BASE_DOMAIN}'.", "Type": "'${INGRESS_RECORD_TYPE}'", "TTL": 300, "ResourceRecords": [{"Value": "'${INGRESS_IP}'"}]}}]' "${SHARED_DIR}/dns_up.json" > "${TMP_DIR}/dns_ingress.json"
  cp "${TMP_DIR}/dns_ingress.json" "${SHARED_DIR}/dns_up.json"
fi

if [ -f "${SHARED_DIR}/MIRROR_REGISTRY_IP" ]; then
  MIRROR_REGISTRY_IP=$(<"${SHARED_DIR}"/MIRROR_REGISTRY_IP)
  if [[ "${MIRROR_REGISTRY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    MIRROR_REGISTRY_RECORD_TYPE="A"
  else
    MIRROR_REGISTRY_RECORD_TYPE="AAAA"
  fi
  echo "Creating Mirror Registry DNS $MIRROR_REGISTRY_RECORD_TYPE record for $CLUSTER_NAME.$BASE_DOMAIN"
  jq '.Changes += [{"Action": "UPSERT", "ResourceRecordSet": {"Name": "mirror-registry.'${CLUSTER_NAME}'.'${BASE_DOMAIN}'.", "Type": "'${MIRROR_REGISTRY_RECORD_TYPE}'", "TTL": 300, "ResourceRecords": [{"Value": "'${MIRROR_REGISTRY_IP}'"}]}}]' "${SHARED_DIR}/dns_up.json" > "${TMP_DIR}/dns_mirror_registry.json"
  cp "${TMP_DIR}/dns_mirror_registry.json" "${SHARED_DIR}/dns_up.json"
fi


cp "${SHARED_DIR}/dns_up.json" "${ARTIFACT_DIR}/"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/dns_up.json"
