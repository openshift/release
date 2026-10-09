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

credential_file_regular=false
credential_file_readable=false
credential_file_nonempty=false
[[ -f "${AWS_SHARED_CREDENTIALS_FILE}" ]] && credential_file_regular=true
[[ -r "${AWS_SHARED_CREDENTIALS_FILE}" ]] && credential_file_readable=true
[[ -s "${AWS_SHARED_CREDENTIALS_FILE}" ]] && credential_file_nonempty=true
echo "AWS credential file status: regular=${credential_file_regular} readable=${credential_file_readable} nonempty=${credential_file_nonempty}"

credential_input_status=()
for credential_input in \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    AWS_SESSION_TOKEN \
    AWS_PROFILE \
    AWS_DEFAULT_PROFILE \
    AWS_CONFIG_FILE \
    AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_ROLE_ARN \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
    AWS_CONTAINER_CREDENTIALS_FULL_URI
do
    credential_input_set=false
    [[ -v "${credential_input}" ]] && credential_input_set=true
    credential_input_status+=("${credential_input}=${credential_input_set}")
done
echo "AWS credential input presence: ${credential_input_status[*]}"
echo "AWS effective credential provider: unavailable (provider resolution was not performed)"

if [[ "${credential_file_regular}" != true || "${credential_file_readable}" != true || "${credential_file_nonempty}" != true ]]
then
    echo "ERROR: expected AWS credential file is not a readable, nonempty regular file" >&2
    exit 1
fi

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

if ! hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
                --dns-name "${base_domain}" \
                --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
                --output text 2>/dev/null)"
then
    echo "ERROR: Route53 hosted-zone lookup failed; verify the mounted credential input and Route53 access using a secure diagnostic channel" >&2
    exit 1
fi

if [[ ! "${hosted_zone_id}" =~ ^(/hostedzone/)?Z[A-Z0-9]+$ ]]
then
    echo "ERROR: Route53 hosted-zone lookup returned no valid public hosted zone" >&2
    exit 1
fi
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

if ! id=$(aws route53 change-resource-record-sets --hosted-zone-id "${hosted_zone_id}" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text 2>/dev/null)
then
    echo "ERROR: Route53 DNS record creation failed" >&2
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Waiting for DNS records to sync..."

if ! aws route53 wait resource-record-sets-changed --id "${id}" >/dev/null 2>&1
then
    echo "ERROR: waiting for Route53 DNS record creation failed" >&2
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - DNS records created."
