#!/usr/bin/env bash

# This script will create a network, subnet, router, then plug the subnet into that network
# and connect the router to the external networ.
# The resources UUIDs are written in SHARED_DIR.

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
    echo "Skipping step due to CONFIG_TYPE not being byon."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

NET_ID="$(openstack network create --format value --column id "${CLUSTER_NAME}-network")"
echo "Created network: ${NET_ID}"
echo $NET_ID>${SHARED_DIR}/MACHINESSUBNET_NET_ID

SUBNET_ID="$(openstack subnet create "${CLUSTER_NAME}-subnet" \
    --network ${NET_ID} \
    --subnet-range ${SUBNET_RANGE} \
    --dns-nameserver ${DNS_IP} \
    --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END} \
    --format value --column id)"
echo "Created subnet: ${SUBNET_ID}"
echo ${SUBNET_ID}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_ID
echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_RANGE
echo ${API_VIP}>${SHARED_DIR}/API_IP
echo ${INGRESS_VIP}>${SHARED_DIR}/INGRESS_IP

ROUTER_ID="$(openstack router create --format value --column id "${CLUSTER_NAME}-router")"
echo "Created router: ${ROUTER_ID}"
echo ${ROUTER_ID}>${SHARED_DIR}/MACHINESSUBNET_ROUTER_ID

openstack router add subnet ${ROUTER_ID} ${SUBNET_ID} >/dev/null
echo "Added subnet ${SUBNET_ID} to router: ${ROUTER_ID}"

openstack router set ${ROUTER_ID} --external-gateway ${OPENSTACK_EXTERNAL_NETWORK} >/dev/null
echo "Connected router ${ROUTER_ID} to external network: ${OPENSTACK_EXTERNAL_NETWORK}"
