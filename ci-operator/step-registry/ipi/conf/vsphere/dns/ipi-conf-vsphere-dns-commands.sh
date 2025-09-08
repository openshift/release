#!/bin/bash

################################################################################################
# This file is no longer used.  It is being left behind temporarily while we migrate to python #
################################################################################################

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
      \"Type\": \"$recordtype\",
      \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"$record\"}]
    }
  }"
  jq --argjson jd "$json_delete" '.Changes += [$jd]' "${SHARED_DIR}"/dns-delete.json > "${SHARED_DIR}"/tmp-delete.json && mv "${SHARED_DIR}"/tmp-delete.json "${SHARED_DIR}"/dns-delete.json
}

echo "vmc-ci.devcluster.openshift.com" > "${SHARED_DIR}"/basedomain.txt

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
cluster_domain="${cluster_name}.${base_domain}"

export AWS_DEFAULT_REGION=us-west-2  # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
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
      echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
      exit 1
    fi
fi

# Load array created in setup-vips:
# 0: API
# 1: Ingress
# 2: Additional cluster API     (optional)
# 3: Additional cluster Ingress (optional)
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

echo "Creating batch file to create DNS records"
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for VSphere IPI CI install",
"Changes": []
}
EOF

echo "Creating batch file to destroy DNS records"
cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for VSphere IPI CI install",
"Changes": []
}
EOF

HOSTNAMES=("api.$cluster_domain." "*.apps.$cluster_domain.")
if [ "${VSPHERE_ADDITIONAL_CLUSTER}" = "true" ]; then
  # Add spoke cluster domain to hostnames in order to provision extra hive cluster
  additional_cluster_name="hive-${cluster_name}-spoke"
  additional_cluster_domain="${additional_cluster_name}.${base_domain}"
  HOSTNAMES+=("api.$additional_cluster_domain." "*.apps.$additional_cluster_domain.")
  cat > "${SHARED_DIR}/additional_cluster.sh" <<EOF
export ADDITIONAL_CLUSTER_NAME=$additional_cluster_name
export ADDITIONAL_CLUSTER_API_VIP=${vips[2]}
export ADDITIONAL_CLUSTER_INGRESS_VIP=${vips[3]}
EOF
fi

for ((i = 0; i < ${#HOSTNAMES[@]}; i++)); do
  echo "Adding ${HOSTNAMES[$i]} to batch files"
  if [ "${JOB_NAME_SAFE}" = "launch" ]; then
    dns_reserve_and_defer_cleanup "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud" ${HOSTNAMES[$i]} "CNAME"
  else
    dns_reserve_and_defer_cleanup ${vips[$i]} ${HOSTNAMES[$i]} "A"
  fi
done

# Snowflake for the default api-int, which shares a vip with the default api.
# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
echo "Adding "api-int.$cluster_domain." to batch files"
dns_reserve_and_defer_cleanup ${vips[0]} "api-int.$cluster_domain." "A"

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "DNS records created."
