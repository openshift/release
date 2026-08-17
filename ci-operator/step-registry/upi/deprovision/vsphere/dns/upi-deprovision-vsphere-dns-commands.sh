#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp


if command -v pwsh &> /dev/null
then
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

  HOSTED_ZONE_ID="$(cat "${SHARED_DIR}/hosted-zone.txt")"

  id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file:///${SHARED_DIR}/dns-delete.json" --query '"ChangeInfo"."Id"' --output text)

  echo "Waiting for Route53 DNS records to be deleted..."

  aws route53 wait resource-record-sets-changed --id "$id"

  if [ -f "${SHARED_DIR}/dns-nodes-delete.json" ]
  then
    id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch file:///"${SHARED_DIR}"/dns-nodes-delete.json --query '"ChangeInfo"."Id"' --output text)
    echo "Waiting for Route53 DNS records for nodes to be deleted..."
    aws route53 wait resource-record-sets-changed --id "$id"
  fi

  echo "Delete successful."
else
  echo "Skipping DNS deprovision due to falling back to Terraform."
fi