#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere-aws/.awscred
source "${SHARED_DIR}/govc.sh"

bastion_path=$(< ${SHARED_DIR}/bastion_host_path)
echo "$(date -u --rfc-3339=seconds) - Deprovisioning bastion host ${bastion_path}"
destroy_ret=0
govc vm.power -off=true ${bastion_path} || true
govc vm.destroy ${bastion_path} || destroy_ret=1

if [[ ${destroy_ret} -eq 1 ]]; then
    echo "ERROR: fail to destroy bastion vm: ${bastion_path}, please check!"
fi

## Destroying DNS resources of mirror registry
if [[ -f "${SHARED_DIR}/bastion-host-dns-delete.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Delete bastion host dns records from aws route53..."
  bastion_hosted_zone_id="$(<"${SHARED_DIR}"/bastion-hosted-zone.txt)"
  id=$(aws route53 change-resource-record-sets --hosted-zone-id "$bastion_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/bastion-host-dns-delete.json --query '"ChangeInfo"."Id"' --output text)
  echo "Waiting for DNS records to sync..."
  aws route53 wait resource-record-sets-changed --id "$id"
  echo "DNS records deleted."
fi
