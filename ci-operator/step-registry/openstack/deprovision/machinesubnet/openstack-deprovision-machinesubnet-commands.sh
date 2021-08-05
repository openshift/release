#!/usr/bin/env bash

# This script remove a network and a router.

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
    echo "Skipping step due to CONFIG_TYPE not being byon."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
NET_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_NET_ID)
SUBNET_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_SUBNET_ID)
ROUTER_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_ROUTER_ID)

>&2 echo "Starting the network cleanup for cluster name $CLUSTER_NAME"
openstack router remove subnet ${ROUTER_ID} ${SUBNET_ID} || >&2 echo "Failed to delete subnet ${SUBNET_ID} from router ${ROUTER_ID}"
openstack router delete ${ROUTER_ID} || >&2 echo "Failed to delete router ${ROUTER_ID}"
openstack network delete ${NET_ID} || >&2 echo "Failed to delete network ${NET_ID}"
>&2 echo 'Cleanup done.'
