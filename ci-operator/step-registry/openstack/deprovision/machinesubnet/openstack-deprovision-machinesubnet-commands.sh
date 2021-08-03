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

>&2 echo "Starting the network cleanup for cluster name $CLUSTER_NAME"
if [[ -f ${SHARED_DIR}"/BASTIONSUBNET_ROUTER_ID" ]]; then
    ROUTER_ID=$(<"${SHARED_DIR}"/BASTIONSUBNET_ROUTER_ID)
    if [[ -f ${SHARED_DIR}"/BASTIONSUBNET_SUBNET_ID" ]]; then
        SUBNET_ID=$(<"${SHARED_DIR}"/BASTIONSUBNET_SUBNET_ID)
        openstack router remove subnet ${ROUTER_ID} ${SUBNET_ID} || >&2 echo "Failed to delete subnet ${SUBNET_ID} from router ${ROUTER_ID}"
    fi
    openstack router delete ${ROUTER_ID} || >&2 echo "Failed to delete router ${ROUTER_ID}"
fi
if [[ -f ${SHARED_DIR}"/BASTIONSUBNET_NET_ID" ]]; then
    NET_ID=$(<"${SHARED_DIR}"/BASTIONSUBNET_NET_ID)
    openstack network delete ${NET_ID} || >&2 echo "Failed to delete network ${NET_ID}"
fi

for p in api ingress; do
  if openstack port show ${CLUSTER_NAME}-${p} >/dev/null; then
    echo "Leftover port exists: ${CLUSTER_NAME}-${p}, probably due to a failure before install, removing it"
    openstack port delete ${CLUSTER_NAME}-${p} || >&2 echo "Failed to delete port ${CLUSTER_NAME}-${p}"
  fi
done

>&2 echo 'Cleanup done.'
