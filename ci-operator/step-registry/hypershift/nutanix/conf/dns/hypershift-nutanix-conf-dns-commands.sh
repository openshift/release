#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Configure DNS for HyperShift Hosted Cluster on Nutanix ************"

# AWS Route 53 credentials
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix-dns/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

# Install AWS CLI if not available
if ! command -v aws &> /dev/null; then
    echo "$(date -u --rfc-3339=seconds) - Installing AWS CLI..."
    export PATH="${HOME}/.local/bin:${PATH}"

    if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]; then
        easy_install --user 'pip<21'
        pip install --user awscli
    elif [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 3 ]; then
        python -m ensurepip
        if command -v pip3 &> /dev/null; then
            pip3 install --user awscli
        elif command -v pip &> /dev/null; then
            pip install --user awscli
        fi
    else
        echo "$(date -u --rfc-3339=seconds) - No pip available, exiting..."
        exit 1
    fi
fi

# Get hosted cluster information
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
BASE_DOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "$(date -u --rfc-3339=seconds) - Configuring DNS for: ${CLUSTER_DOMAIN}"

# Get INGRESS_VIP from nutanix_context.sh (set during management cluster IPI installation)
source "${SHARED_DIR}/nutanix_context.sh"

if [ -z "${INGRESS_VIP:-}" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: INGRESS_VIP not found in nutanix_context.sh"
    echo "$(date -u --rfc-3339=seconds) - This should have been set during management cluster IPI installation"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Management cluster INGRESS_VIP: ${INGRESS_VIP}"

# Build ResourceRecords JSON array with INGRESS_VIP
RESOURCE_RECORDS="[{\"Value\": \"${INGRESS_VIP}\"}]"

echo "$(date -u --rfc-3339=seconds) - Finding Route 53 hosted zone for ${BASE_DOMAIN}"

# Find Route 53 hosted zone
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "${BASE_DOMAIN}" \
    --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${BASE_DOMAIN}.\`].Id" \
    --output text)

if [ -z "${HOSTED_ZONE_ID}" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: No public hosted zone found for ${BASE_DOMAIN}"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Using hosted zone: ${HOSTED_ZONE_ID}"
echo "${HOSTED_ZONE_ID}" > "${SHARED_DIR}/hosted-zone.txt"

# Create DNS record batch file for creation
echo "$(date -u --rfc-3339=seconds) - Creating DNS records batch file"
cat > "${SHARED_DIR}/hosted-dns-create.json" <<EOF
{
  "Comment": "Create DNS records for HyperShift hosted cluster on Nutanix",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.${CLUSTER_DOMAIN}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": ${RESOURCE_RECORDS}
    }
  },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.apps.${CLUSTER_DOMAIN}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": ${RESOURCE_RECORDS}
    }
  }]
}
EOF

# Create DNS record batch file for deletion (used in cleanup)
echo "$(date -u --rfc-3339=seconds) - Creating DNS deletion batch file"
cat > "${SHARED_DIR}/hosted-dns-delete.json" <<EOF
{
  "Comment": "Delete DNS records for HyperShift hosted cluster on Nutanix",
  "Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api.${CLUSTER_DOMAIN}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": ${RESOURCE_RECORDS}
    }
  },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "*.apps.${CLUSTER_DOMAIN}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": ${RESOURCE_RECORDS}
    }
  }]
}
EOF

# Apply DNS records to Route 53
echo "$(date -u --rfc-3339=seconds) - Creating DNS records in Route 53"
CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch file:///"${SHARED_DIR}"/hosted-dns-create.json \
    --query '"ChangeInfo"."Id"' \
    --output text)

echo "$(date -u --rfc-3339=seconds) - Change initiated: ${CHANGE_ID}"
echo "$(date -u --rfc-3339=seconds) - Waiting for DNS records to sync..."

# Wait for DNS propagation
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"

echo "$(date -u --rfc-3339=seconds) - DNS records created successfully:"
echo "  api.${CLUSTER_DOMAIN} → ${WORKER_IPS[@]}"
echo "  *.apps.${CLUSTER_DOMAIN} → ${WORKER_IPS[@]}"
