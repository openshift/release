#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${BASE_DOMAIN:?BASE_DOMAIN env variable should be defined}" > "${SHARED_DIR}"/basedomain.txt

cluster_name="${NAMESPACE}-${UNIQUE_HASH}"
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_domain="${cluster_name}.${base_domain}"

export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}"
    if command -v pip3 &> /dev/null
    then
        pip3 install --user awscli
    else
        if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
        then
          easy_install --user 'pip<21'
          pip install --user awscli
        else
          echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
          exit 1
        fi
    fi
fi

source "${SHARED_DIR}/nutanix_context.sh"

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
echo "$(date -u --rfc-3339=seconds) - Creating DNS records ..."
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create OpenShift DNS records for Nutanix IPI CI install",
"Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${API_VIP}"}]
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api-int.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${API_VIP}"}]
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.apps.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${INGRESS_VIP}"}]
      }
}]}
EOF

echo "$(date -u --rfc-3339=seconds) - Creating batch file to destroy DNS records"

# api-int record is needed for Windows nodes
# TODO: Remove the api-int entry in future
cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for Nutanix IPI CI install",
"Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${API_VIP}"}]
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api-int.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${API_VIP}"}]
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "*.apps.${cluster_domain}.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${INGRESS_VIP}"}]
      }
}]}
EOF

id=$(aws route53 change-resource-record-sets --hosted-zone-id "${hosted_zone_id}" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "$(date -u --rfc-3339=seconds) - Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "${id}"

echo "$(date -u --rfc-3339=seconds) - DNS records created."
