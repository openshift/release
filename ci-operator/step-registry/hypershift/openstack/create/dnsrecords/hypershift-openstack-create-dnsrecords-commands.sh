#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
HOSTED_ZONE_ID="$(</var/run/aws/shiftstack-zone-id)"

export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json
export AWS_PROFILE=profile

# This was taken from other Hypershift jobs, this is how the hosted cluster
# is named in CI.
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INGRESS_FIP="$(<"${SHARED_DIR}/HCP_INGRESS_FIP")"

echo "Creating DNS records for $CLUSTER_NAME.$BASE_DOMAIN"
cat > "${SHARED_DIR}/dns_up.json" <<EOF
{
  "Comment": "Upsert records for ${CLUSTER_NAME}.${BASE_DOMAIN}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${INGRESS_FIP}"
          }
        ]
      }
    }
  ]
}
EOF
cp "${SHARED_DIR}/dns_up.json" "${ARTIFACT_DIR}/"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/dns_up.json"
