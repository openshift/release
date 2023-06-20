#!/bin/bash

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

cluster_hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${cluster_name}.${base_domain}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${cluster_name}.${base_domain}.\`].Id" \
            --output text)"
echo "${cluster_hosted_zone_id}" > "${SHARED_DIR}/cluster-hosted-zone.txt"

dns_create_str=""
dns_delete_str=""
while read -r line; do
  rhel_hostname=$(echo $line | awk '{print $1}')
  rhel_ip=$(echo $line | awk '{print $2}')
  dns_target='"TTL": 60,"ResourceRecords": [{"Value": "'${rhel_ip}'"}]'
  upsert_str="{\"Action\": \"UPSERT\",\"ResourceRecordSet\": {\"Name\": \"${rhel_hostname}.$cluster_domain.\",\"Type\": \"A\",$dns_target}}"
  delete_str="{\"Action\": \"DELETE\",\"ResourceRecordSet\": {\"Name\": \"${rhel_hostname}.$cluster_domain.\",\"Type\": \"A\",$dns_target}}"
  dns_create_str="${upsert_str},${dns_create_str}"
  dns_delete_str="${delete_str},${dns_delete_str}"
done < "${SHARED_DIR}"/rhel_nodes_info

echo "Creating DNS records..."
cat > "${SHARED_DIR}"/rhel-dns-create.json <<EOF
{"Comment": "Create public OpenShift DNS records for rhel workers on vSphere","Changes": [${dns_create_str::-1}]}
EOF

cat > "${SHARED_DIR}"/rhel-dns-delete.json <<EOF
{"Comment": "Delete public OpenShift DNS records for rhel workers on vSphere","Changes": [${dns_delete_str::-1}]}
EOF

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$cluster_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/rhel-dns-create.json --query '"ChangeInfo"."Id"' --output text)
echo "Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "$id"
echo "DNS records created."
