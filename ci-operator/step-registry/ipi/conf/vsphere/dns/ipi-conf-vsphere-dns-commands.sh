#!/bin/bash

dns_reserve_and_defer_cleanup() {
  idx=$1
  hostname=$2

  if [ "${JOB_NAME_SAFE}" = "launch" ]; then
    if [ "$idx" -eq 0 ]; then
      # api dns target
      # setup DNS records for clusterbot to point to the IBM VIP
      dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "[{"Value": "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud"}]'
    elif [ "$idx" -eq 1 ]; then
      # apps dns target
      dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud"}]'
    fi 
  else
    dns_target='"TTL": 60,
    "ResourceRecords": [{"Value": "'${vips[$idx]}'"}]'
  fi 

  json_create="{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"$hostname\",
      \"Type\": \"$RECORD_TYPE\",
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

if [ "${VSPHERE_ADDITIONAL_CLUSTER}" = "true" ]; then
  source "${SHARED_DIR}/vsphere_context.sh"
  source "${SHARED_DIR}/govc.sh"

  network_name="$(jq -r '.metadata.name' ${SHARED_DIR}/NETWORK_single.json)" #FIXME confirm

  echo "1) $GOVC_DATACENTER, 2) $GOVC_DATASTORE, 3) $network_name, 4) $VCENTER"


  # Spoke
  cluster_name_spoke="hive-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  cluster_domain_spoke="${cluster_name_spoke}.${base_domain}"

  # FIXME: temporary workaround
  env_file="${SHARED_DIR}/vsphere_env.txt"
  echo "#!/bin/bash" > "$env_file"

  echo "export CLUSTER_NAME=$cluster_name_spoke" > $env_file
  echo "export BASE_DOMAIN=$base_domain" > $env_file
  echo "export NETWORK_NAME=$network_name" > $env_file
  echo "export VSPHERE_CLUSTER=DEVQEcluster" > $env_file
  echo "export VCENTER=$VCENTER" > $env_file

  # Export creds created in ipi-conf-vsphere-check-vcm-commands.sh
  echo "export GOVC_USERNAME=$GOVC_USERNAME" > "$env_file"
  echo "export GOVC_PASSWORD=$GOVC_PASSWORD" > "$env_file"
  echo "export GOVC_TLS_CA_CERTS=$GOVC_TLS_CA_CERTS" > "$env_file"

  echo "export GOVC_DATACENTER=$GOVC_DATACENTER"> "$env_file"
  echo "export GOVC_DATASTORE=$GOVC_DATASTORE"> "$env_file"

  chmod +x "$env_file"
  # FIXME what hive spoke information must be saved for hub?

fi

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
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
            --output text)"
echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

RECORD_TYPE="A"

if [ "${JOB_NAME_SAFE}" = "launch" ]; then
  # setup DNS records for clusterbot to point to the IBM VIP
  api_dns_target='"TTL": 60, "ResourceRecords": [{"Value": "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud"}]'
  apps_dns_target='"TTL": 60, "ResourceRecords": [{"Value": "vsphere-clusterbot-2284482-dal12.clb.appdomain.cloud"}]'
  RECORD_TYPE="CNAME"
else
  # Configure DNS direct to respective VIP
  api_dns_target='"TTL": 60, "ResourceRecords": [{"Value": "'${vips[0]}'"}]'
  apps_dns_target='"TTL": 60, "ResourceRecords": [{"Value": "'${vips[1]}'"}]'
fi



HOSTNAMES=("api.$cluster_domain." "*.apps.$cluster_domain.")
if [ "$HIVE" -eq 1 ]; then # FXIME BOOLEAN
  # Add spoke cluster domain to hostnames in order to provision extra hive cluster
  HOSTNAMES+=("api.$cluster_domain_spoke." "*.apps.$cluster_domain_spoke.")
fi

for ((i = 0; i < ${#HOSTNAMES[@]}; i++)); do
  echo "Adding ${HOSTNAMES[$i]} to batch files"
  dns_reserve_and_defer_cleanup $i ${HOSTNAMES[$i]}  # $i is the index in vips.txt
done
# Snowflake for the default api-int, which shares a vip with the default api.
echo "Adding "api-int.$cluster_domain" to batch files"
RECORD_TYPE="A"
dns_reserve_and_defer_cleanup 0 "api-int.$cluster_domain."


# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
echo "Creating DNS records..."
cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for VSphere IPI CI install",
"Changes": []
}

"Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.$cluster_domain.",
      "Type": "$RECORD_TYPE",
      $api_dns_target
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api-int.$cluster_domain.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${vips[0]}"}]
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.apps.$cluster_domain.",
      "Type": "$RECORD_TYPE",
      $apps_dns_target
      }
}]}
EOF

# api-int record is needed for Windows nodes
# TODO: Remove the api-int entry in future
echo "Creating batch file to destroy DNS records"

cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for VSphere IPI CI install",
"Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api.$cluster_domain.",
      "Type": "A",
      $api_dns_target
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "api-int.$cluster_domain.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${vips[0]}"}]
      }
    },{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "*.apps.$cluster_domain.",
      "Type": "A",
      $apps_dns_target
      }
}]}
EOF

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for DNS records to sync..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "DNS records created."
