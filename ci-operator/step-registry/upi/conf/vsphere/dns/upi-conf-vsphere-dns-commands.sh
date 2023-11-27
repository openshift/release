#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare base_domain="vmc-ci.devcluster.openshift.com"

if ! command -v pwsh &> /dev/null
then
  echo "Skipping DNS setting due to falling back to Terraform."
  exit 0
else
  echo "${base_domain}" > "${SHARED_DIR}"/basedomain.txt

  cluster_name=${NAMESPACE}-${UNIQUE_HASH}
  cluster_domain="${cluster_name}.${base_domain}"

  export AWS_DEFAULT_REGION=us-west-2  # TODO: Derive this?
  export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
  export AWS_MAX_ATTEMPTS=50
  export AWS_RETRY_MODE=adaptive
  export HOME=/tmp

  if ! command -v aws &> /dev/null
  then
      echo "AWS cli not found.  Installing AWS cli..."
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
            echo "No pip available exiting..."
            exit 1
          fi
      fi
  fi

  # Load array created in setup-vips:
  # 0: API
  # 1: Ingress
  declare -a vips
  if [ -f "${SHARED_DIR}/vips.txt" ]
  then
    mapfile -t vips < "${SHARED_DIR}"/vips.txt
  else
    echo "Unable to find vips.txt"
    exit 1
  fi

  hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
              --dns-name "${base_domain}" \
              --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
              --output text)"
  echo "${hosted_zone_id}" > "${SHARED_DIR}/hosted-zone.txt"

  if [ "${JOB_NAME_SAFE}" = "launch" ]; then
    # setup DNS records for clusterbot to point to the IBM VIP
    api_dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "'${vips[0]}'"}, {"Value": "169.48.190.20"}]'
    apps_dns_target='"TTL": 60,
      "ResourceRecords": [{"Value": "169.48.190.20"}]'
  else
    # Configure DNS direct to respective VIP
    api_dns_target='"TTL": 60,
          "ResourceRecords": [{"Value": "'${vips[0]}'"}]'
    apps_dns_target='"TTL": 60,
          "ResourceRecords": [{"Value": "'${vips[1]}'"}]'
  fi

  # api-int record is needed just for Windows nodes
  # TODO: Remove the api-int entry in future
  echo "Creating DNS records..."
  cat > "${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for VSphere UPI CI install",
"Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.$cluster_domain.",
      "Type": "A",
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
      "Type": "A",
      $apps_dns_target
      }
}]}
EOF

  # api-int record is needed for Windows nodes
  # TODO: Remove the api-int entry in future
  echo "Creating batch file to destroy DNS records"

  cat > "${SHARED_DIR}"/dns-delete.json <<EOF
{
"Comment": "Delete public OpenShift DNS records for VSphere UPI CI install",
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

  if [ -f "${SHARED_DIR}/dns-nodes-create.json" ]
  then
    id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-nodes-create.json --query '"ChangeInfo"."Id"' --output text)
    echo "Waiting for DNS records for nodes to sync..."
    aws route53 wait resource-record-sets-changed --id "$id"
  fi
fi
