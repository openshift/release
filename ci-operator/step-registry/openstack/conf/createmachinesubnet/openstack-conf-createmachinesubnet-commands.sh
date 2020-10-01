#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)


#Create network, tag it, and get its UID
NET_ID=$(openstack network create "${CLUSTER_NAME}-network" | grep " id " | awk '{ print $4 }')
echo $NET_ID>${SHARED_DIR}/MACHINESSUBNET_NET_ID

#create subnet and tag
SUBNET_ID=$(openstack subnet create "${CLUSTER_NAME}-subnet" \
          --network ${NET_ID} --subnet-range ${SUBNET_RANGE} \
          --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END} \
          | grep " id " | awk '{ print $4 }')
echo ${SUBNET_ID}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_ID
echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_RANGE

#create router
ROUTER_ID=$(openstack router create "${CLUSTER_NAME}-router" | grep " id " | awk '{ print $4 }')
echo ${ROUTER_ID}>${SHARED_DIR}/MACHINESSUBNET_ROUTER_ID

#attach subnet to router
openstack router add subnet ${ROUTER_ID} ${SUBNET_ID}

#attach to external network
openstack router set ${ROUTER_ID} --external-gateway ${OPENSTACK_EXTERNAL_NETWORK}


