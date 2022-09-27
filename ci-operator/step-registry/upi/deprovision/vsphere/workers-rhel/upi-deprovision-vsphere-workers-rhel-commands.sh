#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere-aws/.awscred
export AWS_DEFAULT_REGION=us-east-1

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
source "${SHARED_DIR}/govc.sh"

echo "$(date -u --rfc-3339=seconds) - Deprovisioning rhel workers of cluster $cluster_name"
vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"
while read -r line; do
  hostname=$(echo "$line" | awk '{print $1}')
  echo "Deprovision ${hostname}"
  govc vm.power -off=true ${vm_path}/${hostname}
  govc vm.destroy ${vm_path}/${hostname}
done < "${SHARED_DIR}"/rhel_nodes_info

echo "$(date -u --rfc-3339=seconds) - Delete rhel node dns records from aws route53..."
cluster_hosted_zone_id="$(<"${SHARED_DIR}"/cluster-hosted-zone.txt)"
id=$(aws route53 change-resource-record-sets --hosted-zone-id "$cluster_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/rhel-dns-delete.json --query '"ChangeInfo"."Id"' --output text)
echo "Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "$id"
echo "DNS records deleted."
