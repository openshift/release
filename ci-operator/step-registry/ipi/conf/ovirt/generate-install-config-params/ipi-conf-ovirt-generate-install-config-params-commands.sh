#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#OVIRT_LEASED_RESOURCE can be a list so we want the name of the first param from the list
lease_path="${CLUSTER_PROFILE_DIR}/${LEASED_RESOURCE%%,*}.json"

function extract_leases_info() {
    echo "$( jq ."${1}" --raw-output "${2}" )"
}

#Saving parameters for the env
cat > ${SHARED_DIR}/ovirt-lease.conf <<EOF
OVIRT_APIVIP="$(extract_leases_info ovirt_apivip ${lease_path})"
OVIRT_DNSVIP="$(extract_leases_info ovirt_dnsvip ${lease_path})"
OVIRT_INGRESSVIP="$(extract_leases_info ovirt_ingressvip ${lease_path})"
OCP_CLUSTER="$(extract_leases_info cluster_name ${lease_path})"
OVIRT_ENGINE_NETWORK="$(extract_leases_info ovirt_network_name ${lease_path})"
OVIRT_STORAGE_DOMAIN_ID="$(extract_leases_info ovirt_storage_domain_id ${lease_path})"
WORKER_CPU="8"
WORKER_MEM="16384"
MASTER_CPU="8"
MASTER_MEM="16384"
EOF
