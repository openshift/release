#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_MAX_ATTEMPTS=7
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

if ! command -v aws &> /dev/null
then

    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    python_version=$(python -c 'import sys;print(sys.version_info.major)')
    export PATH="${HOME}/.local/bin:${PATH}"
    if [[ $python_version -eq 2 ]]
    then
        easy_install --user 'pip<21'  # our Python 2.7.5 is even too old for ensurepip
        pip install --user awscli
    elif [[ $python_version -eq 3 ]]
    then
        pip3 install --user awscli
    else
        echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
        exit 1
    fi
fi

HOSTED_ZONE_ID="$(cat "${SHARED_DIR}/hosted-zone.txt")"

id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file:///${SHARED_DIR}/dns-delete.json" --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for Route53 DNS records to be deleted..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "Delete successful."
