#!/bin/bash

dns_reserve_and_defer_cleanup() {
  idx=$1
  hostname=$2

  if [ "${JOB_NAME_SAFE}" = "launch" ]; then
    if [ "$idx" -eq 0 ]; then
      # setup DNS records for clusterbot to point to the IBM VIP
      dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "'${vips[0]}'"}, {"Value": "169.48.190.20"}]'
    elif [ "$idx" -eq 1 ]; then
      dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "169.48.190.20"}]'
    fi 
  else
    dns_target='"TTL": 60,
    "ResourceRecords": [{"Value": "'${vips[$idx]}'"}]'
  fi 


  json_create="{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"A\",
      $dns_target
    }
  }"
  jq --argjson jc "$json_create" '.Changes += [$jc]' "${SHARED_DIR}"/dns-create.json > "${SHARED_DIR}"/tmp.json && mv "${SHARED_DIR}"/tmp.json "${SHARED_DIR}"/dns-create.json

  json_delete="{
    \"Action\": \"DELETE\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"A\",
      $dns_target
    }
  }"
  jq --argjson jd "$json_delete" '.Changes += [$jd]' "${SHARED_DIR}"/dns-delete.json > "${SHARED_DIR}"/tmp.json && mv "${SHARED_DIR}"/tmp.json "${SHARED_DIR}"/dns-delete.json

}

set -o nounset
set -o errexit
set -o pipefail

echo "vmc-ci.devcluster.openshift.com" > "${SHARED_DIR}"/basedomain.txt

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_domain="${cluster_name}.${base_domain}"

export AWS_DEFAULT_REGION=us-west-2  # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
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

# Load array created in setup-vips:
# 0: API
# 1: Ingress
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
echo "Creating DNS records..."
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for VSphere IPI CI install",
"Changes": []
}
EOF

# api-int record is needed for Windows nodes
# TODO: Remove the api-int entry in future
echo "Creating batch file to destroy DNS records"

cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for VSphere IPI CI install",
"Changes": []
}
EOF

# FIXME: Temporary workaround
source "${SHARED_DIR}/vsphere_env.txt"
read -a vsphere_basedomains_list <<< "$VSPHERE_ADDITIONAL_BASEDOMAINS"

HOSTNAMES=("api.$cluster_domain." "*.apps.$cluster_domain.")
for cluster in "${vsphere_basedomains_list[@]}"; do
  HOSTNAMES+=("api.$cluster.${base_domain}." "*.apps.$cluster.${base_domain}.")
done

for ((i = 0; i < ${#HOSTNAMES[@]}; i++)); do
  echo "Adding ${HOSTNAMES[$i]} to batch files"
  dns_reserve_and_defer_cleanup $i ${HOSTNAMES[$i]}  # $i is the index in vips.txt
done
# Snowflake for the default api-int, which shares a vip with the default api.
dns_reserve_and_defer_cleanup 0 "api-int.$cluster_domain"

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "DNS records created."
