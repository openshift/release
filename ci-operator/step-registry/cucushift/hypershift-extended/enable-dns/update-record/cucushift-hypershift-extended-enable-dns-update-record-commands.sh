#!/bin/bash
#Get controlplane endpoint
if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_namename: $CLUSTER_NAME"
KAS_DNS_NAME=$(oc get hostedclusters/${CLUSTER_NAME} -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.spec.kubeAPIServerDNSName}')
if [[ -z "${KAS_DNS_NAME}" ]]; then
    echo " No custom dns configured"
    exit 1
fi 
CP_EP=$(oc get hostedclusters/${CLUSTER_NAME} -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.status.controlPlaneEndpoint.host}')

#Update route53 record value
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" --output text | cut -d'/' -f3)
if [ -z "${HOSTED_ZONE_ID}" ]; then
  echo "hosted zone id does not exist."
  exit 1
fi

RECORD_NAME="${KAS_DNS_NAME}."
EXISTING_TTL=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}' && Type=='CNAME'].TTL" \
  --output text)
if [ -z "$EXISTING_TTL" ]; then
   echo "Cannot find valid ttl"
   exit 1
fi

cat << EOF > /tmp/temp-change.json
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "CNAME",
        "TTL": ${EXISTING_TTL},
        "ResourceRecords": [
          {
            "Value": "${CP_EP}"
          }
        ]
      }
    }
  ]
}
EOF

echo "Updating..."
if aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file:///tmp/temp-change.json" >/dev/null 2>&1; then
  echo "Record upated successed"
else
  echo "Record upated failed" >&2
  exit 1
fi
id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch file:///tmp/temp-change.json --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "${id}"

# Clear temp file
rm -f /tmp/temp-change.json
