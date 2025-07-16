#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/public_custom_dns.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: File '${SHARED_DIR}/public_custom_dns.json' doesn't exist, abort."
  exit 1
fi

dns_reserve_and_defer_cleanup() {
  record=$1
  hostname=$2
  recordtype=$3

  json_create="{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"$recordtype\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jc "$json_create" '.Changes += [$jc]' "${SHARED_DIR}"/dns-create.json > "${SHARED_DIR}"/tmp-create.json && mv "${SHARED_DIR}"/tmp-create.json "${SHARED_DIR}"/dns-create.json

  json_delete="{
    \"Action\": \"DELETE\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"$recordtype\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jd "$json_delete" '.Changes += [$jd]' "${SHARED_DIR}"/dns-delete.json > "${SHARED_DIR}"/tmp-delete.json && mv "${SHARED_DIR}"/tmp-delete.json "${SHARED_DIR}"/dns-delete.json
}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/route53.only.awscred"
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

ret=0

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${BASE_DOMAIN}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

echo "$(date -u --rfc-3339=seconds) - INFO: Creating batch file to create DNS records"
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for GCP custom dns IPI CI install",
"Changes": []
}
EOF

echo "$(date -u --rfc-3339=seconds) - INFO: Creating batch file to destroy DNS records"
cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for GCP custom dns IPI CI install",
"Changes": []
}
EOF

count=$(jq '.|length' ${SHARED_DIR}/public_custom_dns.json)
for i in $(seq 0 $((count-1)));
do
    name=$(jq --argjson i $i -r '.[$i].name' ${SHARED_DIR}/public_custom_dns.json)
    target=$(jq --argjson i $i -r '.[$i].target' ${SHARED_DIR}/public_custom_dns.json)
    record_type=$(jq --argjson i $i -r '.[$i].record_type' ${SHARED_DIR}/public_custom_dns.json)

    if [[ -n "${target}" ]]; then
        echo "$(date -u --rfc-3339=seconds) - INFO: Adding '${name} ${target}' to batch files"
        dns_reserve_and_defer_cleanup "${target}" "${name}" "${record_type}"
    else
        echo "$(date -u --rfc-3339=seconds) - ERROR: Empty VIP for '${name}', skipped."
        ret=1
    fi
done

echo "dns-create.json:"
cat "${SHARED_DIR}/dns-create.json"


id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "$(date -u --rfc-3339=seconds) - INFO: Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "$(date -u --rfc-3339=seconds) - INFO: DNS records created."
exit "${ret}"