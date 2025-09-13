#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${BASE_DOMAIN:?BASE_DOMAIN env variable should be defined}" > "${SHARED_DIR}"/basedomain.txt

cluster_name="${NAMESPACE}-${UNIQUE_HASH}"
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_domain="${cluster_name}.${base_domain}"

if [[ "${HIVE_NUTANIX_RESOURCE}" == "true" ]]; then
  HIVE_CLUSTER_NAME="${cluster_name}-hive"
  echo "export HIVE_CLUSTER_NAME=\"${HIVE_CLUSTER_NAME}\"" >> "${SHARED_DIR}/nutanix_context.sh" || {
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to set HIVE_CLUSTER_NAME in nutanix_context.sh"
    exit 1
  }
fi

export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}" 

    if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
    then
      easy_install --user 'pip<21'
      pip install --user awscli
    elif [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 3 ]
    then
      python -m ensurepip
      if command -v pip3 &> /dev/null
      then        
        pip3 install --user awscli
      elif command -v pip &> /dev/null
      then
        pip install --user awscli
      fi
    else    
      echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
      exit 1
    fi
fi

source "${SHARED_DIR}/nutanix_context.sh"

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

echo "$(date -u --rfc-3339=seconds) - Creating DNS records ..."
DNS_RECORD_FILE="${SHARED_DIR}/dns-create.json"

if [[ ! -f "${DNS_RECORD_FILE}" ]]; then
  cat > "${DNS_RECORD_FILE}" <<EOF
{
  "Comment": "Upsert records for ${cluster_domain}",
  "Changes": []
}
EOF
fi

add_dns_record() {
  local file=$1
  local action=$2
  local name=$3
  local ip=$4
  local ttl=${5:-60}

  local record_type
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    record_type="A"
  else
    record_type="AAAA"
  fi

  jq --arg action "$action" --arg name "$name" --arg type "$record_type" --argjson ttl "$ttl" --arg ip "$ip" \
    '.Changes += [{
      "Action": $action,
      "ResourceRecordSet": {
        "Name": $name,
        "Type": $type,
        "TTL": $ttl,
        "ResourceRecords": [{"Value": $ip}]
      }
    }]' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
add_dns_record "${SHARED_DIR}/dns-create.json" "UPSERT" "api.${cluster_domain}." "${API_VIP}"
add_dns_record "${SHARED_DIR}/dns-create.json" "UPSERT" "api-int.${cluster_domain}." "${API_VIP}"
add_dns_record "${SHARED_DIR}/dns-create.json" "UPSERT" "*.apps.${cluster_domain}." "${INGRESS_VIP}"

if [[ "${HIVE_NUTANIX_RESOURCE}" == "true" ]]; then
  if [[ -z "${HIVE_API_VIP:-}" || -z "${HIVE_INGRESS_VIP:-}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: HIVE API or Ingress VIP not found in nutanix_context.sh"
    exit 1
  fi
  echo "$(date -u --rfc-3339=seconds) - Adding Hive DNS records..."
  add_dns_record "${SHARED_DIR}/dns-create.json" "UPSERT" "api.${HIVE_CLUSTER_NAME}.${base_domain}." "${HIVE_API_VIP}"
  add_dns_record "${SHARED_DIR}/dns-create.json" "UPSERT" "ingress.${HIVE_CLUSTER_NAME}.${base_domain}." "${HIVE_INGRESS_VIP}"
fi

echo "$(date -u --rfc-3339=seconds) - Creating batch file to destroy DNS records..."

id=$(aws route53 change-resource-record-sets --hosted-zone-id "${hosted_zone_id}" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "$(date -u --rfc-3339=seconds) - Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "${id}"

echo "$(date -u --rfc-3339=seconds) - DNS records created."
