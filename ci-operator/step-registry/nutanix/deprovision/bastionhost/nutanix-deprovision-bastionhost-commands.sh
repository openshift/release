#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function get_vm_uuid() {
   BASTION_UUID=$(curl -k -X POST --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/vms/list" \
      -d '{ "kind": "vm","filter": "","length": 60,"offset": 0}' |
      jq -r '.entities[] | select(.spec.name == "'"${bastion_name}"'") | .metadata.uuid')
}

function delete_vm() {
  get_vm_uuid
  curl -k -X 'DELETE' --header "Content-Type: application/json" \
      --header "Accept: application/json" \
      --header "Authorization: Basic ${ENCODED_CREDS}" \
      "https://${NUTANIX_HOST}:${NUTANIX_PORT}/api/nutanix/v3/vms/${BASTION_UUID}"
}

# shellcheck source=/dev/null
source "${SHARED_DIR}/nutanix_context.sh"

ENCODED_CREDS="$(echo -n "${NUTANIX_USERNAME}:${NUTANIX_PASSWORD}" | base64)"
bastion_name=$(< "${SHARED_DIR}"/bastion_name)
delete_vm

## Destroying DNS resources of mirror registry
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix/.awscred
if [[ -f "${SHARED_DIR}/bastion-host-dns-delete.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Delete bastion host dns records from aws route53..."
  bastion_hosted_zone_id="$(<"${SHARED_DIR}"/bastion-hosted-zone.txt)"
  id=$(aws route53 change-resource-record-sets --hosted-zone-id "$bastion_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/bastion-host-dns-delete.json --query '"ChangeInfo"."Id"' --output text)
  echo "Waiting for DNS records to sync..."
  aws route53 wait resource-record-sets-changed --id "$id"
  echo "DNS records deleted."
fi
