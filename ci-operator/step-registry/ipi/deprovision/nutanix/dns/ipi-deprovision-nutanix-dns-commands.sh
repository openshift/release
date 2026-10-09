#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

hosted_zone_file="${SHARED_DIR}/hosted-zone.txt"
delete_batch_file="${SHARED_DIR}/dns-delete.json"

if [[ ! -e "${hosted_zone_file}" && ! -L "${hosted_zone_file}" ]]
then
    echo "$(date -u --rfc-3339=seconds) - No Nutanix DNS setup state found; nothing to delete."
    exit 0
fi

if [[ ! -f "${hosted_zone_file}" || ! -r "${hosted_zone_file}" || ! -s "${hosted_zone_file}" ]]
then
    echo "ERROR: Nutanix DNS setup state exists but hosted-zone.txt is not a readable, nonempty file" >&2
    exit 1
fi

HOSTED_ZONE_ID="$(<"${hosted_zone_file}")"
if [[ ! "${HOSTED_ZONE_ID}" =~ ^(/hostedzone/)?Z[A-Z0-9]+$ ]]
then
    echo "ERROR: Nutanix DNS setup state contains an invalid hosted zone ID" >&2
    exit 1
fi

if [[ ! -f "${delete_batch_file}" || ! -r "${delete_batch_file}" || ! -s "${delete_batch_file}" ]]
then
    echo "ERROR: Nutanix DNS setup state exists but dns-delete.json is missing, unreadable, or empty" >&2
    exit 1
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

if ! id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file:///${SHARED_DIR}/dns-delete.json" --query '"ChangeInfo"."Id"' --output text 2>/dev/null)
then
    echo "ERROR: Route53 DNS record deletion failed" >&2
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Waiting for Route53 DNS records to be deleted..."

if ! aws route53 wait resource-record-sets-changed --id "$id" >/dev/null 2>&1
then
    echo "ERROR: waiting for Route53 DNS record deletion failed" >&2
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Delete successful."
