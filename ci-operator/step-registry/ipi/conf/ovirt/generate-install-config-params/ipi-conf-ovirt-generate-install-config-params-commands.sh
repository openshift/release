#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#OVIRT_LEASED_RESOURCE can be a list so we want the name of the first param from the list
lease_path="${CLUSTER_PROFILE_DIR}/${LEASED_RESOURCE%%,*}.json"

function extract_leases_info() {
    echo "$( jq ."${1}" --raw-output "${2}" )"
}

if [ "${LEASE_TYPE}" == "conformance" ]; then
  worker_cpu="8"
  worker_mem="16384"
  master_cpu="8"
  master_mem="16384"
else
  worker_cpu="4"
  worker_mem="10240"
  master_cpu="4"
  master_mem="10240"
fi

#Saving parameters for the env
cat > ${SHARED_DIR}/ovirt-lease.conf <<EOF
OVIRT_APIVIP="$(extract_leases_info ovirt_apivip ${lease_path})"
OVIRT_DNSVIP="$(extract_leases_info ovirt_dnsvip ${lease_path})"
OVIRT_INGRESSVIP="$(extract_leases_info ovirt_ingressvip ${lease_path})"
WORKER_CPU="$(extract_leases_info ovirt_ingressvip ${lease_path})"
WORKER_CPU="${worker_cpu}"
WORKER_MEM="${worker_mem}"
MASTER_CPU="${master_cpu}"
MASTER_MEM="${master_mem}"
OCP_CLUSTER="$(extract_leases_info cluster_name ${lease_path})"
OVIRT_ENGINE_NETWORK="$(extract_leases_info ovirt_network_name ${lease_path})"
EOF
