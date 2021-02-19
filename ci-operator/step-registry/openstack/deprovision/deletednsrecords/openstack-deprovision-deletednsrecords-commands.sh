#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json
export AWS_PROFILE=profile

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}" | python -c '
import json,sys
print(json.load(sys.stdin)["HostedZones"][0]["Id"].split("/")[-1])'
)

for RECORD_FILE in api-record.json ingress-record.json
do
    if [[ -f "${SHARED_DIR}/${RECORD_FILE}" ]]; then
        echo Deleting ${RECORD_FILE}
        sed '
            s/UPSERT/DELETE/;
            s/Create/Delete/;
            ' "${SHARED_DIR}/${RECORD_FILE}" > "${SHARED_DIR}/delete-${RECORD_FILE}"
        aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/delete-${RECORD_FILE}" || echo "Failed deleting ${RECORD_FILE}"
    else
        echo ${RECORD_FILE} NOT found. DNS record not deleted.
    fi
done
