#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

HOSTED_ZONE_ID="$(cat "${SHARED_DIR}/hosted-zone.txt")"

if [[ -f "${SHARED_DIR}/dns-create.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Converting UPSERTs to DELETEs..."
  sed '
	    s/UPSERT/DELETE/;
	    s/Upsert/Delete/;
	    ' "${SHARED_DIR}/dns-create.json" > "${SHARED_DIR}/dns-delete.json"
  cp "${SHARED_DIR}/dns-delete.json" "${ARTIFACT_DIR}/"

  echo "$(date -u --rfc-3339=seconds) - Submitting DNS record deletions to Route53..."
  id=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "file://${SHARED_DIR}/dns-delete.json" \
    --query 'ChangeInfo.Id' --output text)

  echo "$(date -u --rfc-3339=seconds) - Waiting for DNS record deletion to complete..."
  aws route53 wait resource-record-sets-changed --id "$id"
  echo "$(date -u --rfc-3339=seconds) - DNS record deletion successful."
else
  echo "$(date -u --rfc-3339=seconds) - File '${SHARED_DIR}/dns-create.json' not found. Skipping DNS deletion."
fi
