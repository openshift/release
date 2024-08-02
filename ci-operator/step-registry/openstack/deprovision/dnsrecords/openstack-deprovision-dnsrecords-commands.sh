#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION=us-east-1
export AWS_DEFAULT_OUTPUT=json

if [ -z "${AWS_PROFILE:-}" ]; then
  unset AWS_PROFILE
fi 

echo "Getting the hosted zone ID for domain: ${BASE_DOMAIN}"
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
            --dns-name "${BASE_DOMAIN}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${BASE_DOMAIN}.\`].Id" \
            --output text)"
			
if [[ -f "${SHARED_DIR}/dns_up.json" ]]; then
	echo "Deleting DNS records."
	sed '
	    s/UPSERT/DELETE/;
	    s/Upsert/Delete/;
	    ' "${SHARED_DIR}/dns_up.json" > "${SHARED_DIR}/dns_down.json"
	cp "${SHARED_DIR}/dns_down.json" "${ARTIFACT_DIR}/"
	aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "file://${SHARED_DIR}/dns_down.json"
else
	echo "File 'dns_up.json' not found. DNS records not deleted."
fi
