#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
      \"Type\": \"A\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jd "$json_delete" '.Changes += [$jd]' "${SHARED_DIR}"/dns-delete.json > "${SHARED_DIR}"/tmp-delete.json && mv "${SHARED_DIR}"/tmp-delete.json "${SHARED_DIR}"/dns-delete.json
}

function find_out_api_and_ingress_ip_addresses() {
  local -r infra_id="$1"
  local -r region="$2"
  local -r out_file="$3"
  local api_ip_address ingress_ip_address ingress_forwarding_rule

  api_ip_address=$(gcloud compute forwarding-rules describe --global "${infra_id}-apiserver" --format json | jq -r .IPAddress)
  ingress_forwarding_rule=$(gcloud compute target-pools list --format=json --filter="instances[]~${infra_id}" | jq -r .[].name)
  if [[ -n "${ingress_forwarding_rule}" ]]; then
    ingress_ip_address=$(gcloud compute forwarding-rules describe --region "${region}" "${ingress_forwarding_rule}" --format json | jq -r .IPAddress)
  else
    ingress_ip_address=""
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the INGRESS forwarding-rule."
  fi

  echo "$(date -u --rfc-3339=seconds) - INFO: Populate the file '${out_file}' with API server IP (${api_ip_address}) and INGRESS server IP (${ingress_ip_address})..."
  cat > "${out_file}"  << EOF
${api_ip_address}
${ingress_ip_address}
EOF
}

AWS_BASE_DOMAIN="qe.devcluster.openshift.com"

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
#cluster_name="ci-op-110jib7j-af877"
cluster_domain="${cluster_name}.${AWS_BASE_DOMAIN}"
INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
#INFRA_ID="ci-op-110jib7j-af877-4p9dw"

export AWS_DEFAULT_REGION=us-west-2  # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/gcp/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp


which python || true
whereis python || true

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
      echo "$(date -u --rfc-3339=seconds) - ERROR: No pip available exiting..."
      exit 1
    fi
fi

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi
GCP_REGION="${LEASED_RESOURCE}"

find_out_api_and_ingress_ip_addresses "${INFRA_ID}" "${GCP_REGION}" "${SHARED_DIR}/vips.txt"

# Load array created in setup-vips:
# 0: API
# 1: Ingress
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${AWS_BASE_DOMAIN}.\`].Id" \
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

HOSTNAMES=("api.$cluster_domain." "*.apps.$cluster_domain.")

for ((i = 0; i < ${#HOSTNAMES[@]}; i++)); do
  echo "$(date -u --rfc-3339=seconds) - INFO: Adding ${HOSTNAMES[$i]} to batch files"
  dns_reserve_and_defer_cleanup ${vips[$i]} ${HOSTNAMES[$i]} "A"
done

#echo "$(date -u --rfc-3339=seconds) - INFO: Saving the dns-create.json for debugging..."
#cp "${SHARED_DIR}"/dns-create.json "${ARTIFACT_DIR}"
id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "$(date -u --rfc-3339=seconds) - INFO: Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "$(date -u --rfc-3339=seconds) - INFO: DNS records created."
