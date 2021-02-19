#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json
export AWS_PROFILE=profile

CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)
INGRESS_FIP_IP=$(<"${SHARED_DIR}"/INGRESS_FIP_IP)
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}" | python -c '
import json,sys;
print(json.load(sys.stdin)["HostedZones"][0]["Id"].split("/")[-1])'
)

cat > ${SHARED_DIR}/api-record.json <<EOF
{
"Comment": "Create the public OpenShift API record",
"Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${LB_FIP_IP}"}]
      }
}]}
EOF
cp ${SHARED_DIR}/api-record.json ${ARTIFACT_DIR}/api-record.json
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://${SHARED_DIR}/api-record.json

echo "Creating DNS record for *.apps.$CLUSTER_NAME.$BASE_DOMAIN. -> $INGRESS_FIP_IP"
cat > ${SHARED_DIR}/ingress-record.json <<EOF
{
"Comment": "Create the public OpenShift Ingress record",
"Changes": [{
  "Action": "UPSERT",
  "ResourceRecordSet": {
    "Name": "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.",
    "Type": "A",
    "TTL": 300,
    "ResourceRecords": [{"Value": "${INGRESS_FIP_IP}"}]
    }
}]}
EOF
cp ${SHARED_DIR}/ingress-record.json ${ARTIFACT_DIR}/ingress-record.json
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://${SHARED_DIR}/ingress-record.json
