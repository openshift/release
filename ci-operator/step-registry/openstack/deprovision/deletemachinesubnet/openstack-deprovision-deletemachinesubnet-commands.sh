#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml

NET_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_NET_ID)
SUBNET_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_SUBNET_ID)
ROUTER_ID=$(<"${SHARED_DIR}"/MACHINESSUBNET_ROUTER_ID)

set +e
#detach subnet from router
openstack router remove subnet ${ROUTER_ID} ${SUBNET_ID}

#delete router
openstack router delete ${ROUTER_ID}

#delete network and subnet
openstack network delete ${NET_ID}

