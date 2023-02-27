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

echo "Creating DNS records for $CLUSTER_NAME.$BASE_DOMAIN"
cat > "${SHARED_DIR}/dns_up.json" <<EOF
{
  "Comment": "Upsert records for ${CLUSTER_NAME}.${BASE_DOMAIN}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${API_IP}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${INGRESS_IP}"
          }
        ]
      }
    }
  ]
}
EOF
cp "${SHARED_DIR}/dns_up.json" "${ARTIFACT_DIR}/"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/dns_up.json"
