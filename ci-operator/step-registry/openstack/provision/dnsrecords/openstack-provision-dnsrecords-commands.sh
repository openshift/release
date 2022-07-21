#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
HOSTED_ZONE_ID="$(</var/run/aws/shiftstack-zone-id)"

export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json
export AWS_PROFILE=profile

CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
API_IP=$(<"${SHARED_DIR}"/API_IP)
INGRESS_IP=$(<"${SHARED_DIR}"/INGRESS_IP)

echo "Creating DNS record for api.$CLUSTER_NAME.$BASE_DOMAIN. -> $API_IP"
cat > "${SHARED_DIR}/api-record.json" <<EOF
{
"Comment": "Create the public OpenShift API record",
"Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${API_IP}"}]
      }
}]}
EOF
cp "${SHARED_DIR}/api-record.json" "${ARTIFACT_DIR}/api-record.json"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/api-record.json"

echo "Creating DNS record for *.apps.$CLUSTER_NAME.$BASE_DOMAIN. -> $INGRESS_IP"
cat > "${SHARED_DIR}/ingress-record.json" <<EOF
{
"Comment": "Create the public OpenShift Ingress record",
"Changes": [{
  "Action": "UPSERT",
  "ResourceRecordSet": {
    "Name": "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.",
    "Type": "A",
    "TTL": 300,
    "ResourceRecords": [{"Value": "${INGRESS_IP}"}]
    }
}]}
EOF
cp "${SHARED_DIR}/ingress-record.json" "${ARTIFACT_DIR}/ingress-record.json"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/ingress-record.json"
