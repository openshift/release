#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function extract_leases_info() {
    echo "$( jq ."${1}" --raw-output "${2}" )"
}

lease_path="${CLUSTER_PROFILE_DIR}/${LEASED_RESOURCE}.json"
storage_domain_id="$(extract_leases_info ovirt_storage_domain_id ${lease_path})"
if [[ -n ${OVIRT_UPGRADE_LEASED_RESOURCE+x} ]]; then
  upgrade_lease_path="${CLUSTER_PROFILE_DIR}/${OVIRT_UPGRADE_LEASED_RESOURCE}.json"
  storage_domain_id="$(extract_leases_info ovirt_storage_domain_id ${upgrade_lease_path})"
  echo "Using storage domain ${storage_domain_id} for upgrade job"
fi

#Saving parameters for the env
cat > ${SHARED_DIR}/ovirt-lease.conf <<EOF
OVIRT_APIVIP="$(extract_leases_info ovirt_apivip ${lease_path})"
OVIRT_DNSVIP="$(extract_leases_info ovirt_dnsvip ${lease_path})"
OVIRT_INGRESSVIP="$(extract_leases_info ovirt_ingressvip ${lease_path})"
OCP_CLUSTER="$(extract_leases_info cluster_name ${lease_path})"
OVIRT_ENGINE_NETWORK="$(extract_leases_info ovirt_network_name ${lease_path})"
OVIRT_STORAGE_DOMAIN_ID="${storage_domain_id}"
MACHINE_NETWORK_CIDR="$(extract_leases_info machine_network_cidr ${lease_path})"
OVIRT_ENGINE_CLUSTER_ID="$(extract_leases_info ovirt_cluster_id ${lease_path})"
WORKER_CPU="8"
WORKER_MEM="16384"
MASTER_CPU="8"
MASTER_MEM="16384"
EOF
