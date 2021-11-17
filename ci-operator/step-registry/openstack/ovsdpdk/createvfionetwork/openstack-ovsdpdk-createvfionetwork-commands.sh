#!/usr/bin/env bash

# This script will create a network, subnet, router, then plug the subnet into that network
# and connect the router to the external networ.
# The resources UUIDs are written in SHARED_DIR.

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
NETWORK_NAME="${CLUSTER_NAME}-vfio-network"
VIFO_NETWORK_ID=$(openstack network create "$NETWORK_NAME" -f value -c 'id')
echo "${VIFO_NETWORK_ID}"  > "${SHARED_DIR}"/VFIO_NETWORK_ID
echo "${VIFO_NETWORK_ID}"  >> "${SHARED_DIR}"/DELETE_NETWORK_IDS
