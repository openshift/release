#!/usr/bin/env bash

# This script will create a network, subnet, router, then plug the subnet into that network
# and connect the router to the external networ.
# The resources UUIDs are written in SHARED_DIR.

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != *"proxy"* ]]; then
    echo "Skipping step due to CONFIG_TYPE not being proxy."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

if [[ -f "${SHARED_DIR}/squid-credentials.txt" ]]; then
    echo "A proxy job that has squid-credentials already will need a public floating IP to work in CI, overriding OPENSTACK_EXTERNAL_NETWORK to be the public proxy network."
    OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK}-proxy"
    if ! openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" >/dev/null; then
        echo "ERROR: External network for the proxy does not exist: ${OPENSTACK_EXTERNAL_NETWORK}"
        exit 1
    fi
fi

BASTION_ROUTER_ID="$(openstack router create --format value --column id "${CLUSTER_NAME}-${CONFIG_TYPE}-router")"
echo "Created bastion router: ${BASTION_ROUTER_ID}"
echo ${BASTION_ROUTER_ID}>${SHARED_DIR}/BASTION_ROUTER_ID
openstack router set ${BASTION_ROUTER_ID} --external-gateway ${OPENSTACK_EXTERNAL_NETWORK} >/dev/null
echo "Connected bastion router ${BASTION_ROUTER_ID} to external network: ${OPENSTACK_EXTERNAL_NETWORK}"

MACHINES_NET_ID="$(openstack network create --format value --column id \
  "${CLUSTER_NAME}-${CONFIG_TYPE}-machines-network" --description "Machines network for ${CLUSTER_NAME}-${CONFIG_TYPE}")"
echo "Created network for OpenShift machines: ${MACHINES_NET_ID}"
echo ${MACHINES_NET_ID}>${SHARED_DIR}/MACHINES_NET_ID

subnet_params=" --network ${MACHINES_NET_ID} --subnet-range ${SUBNET_RANGE} \
  --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END}"

MACHINES_SUBNET_ID="$(openstack subnet create "${CLUSTER_NAME}-${CONFIG_TYPE}-machines-subnet" $subnet_params \
  --description "Machines subnet for ${CLUSTER_NAME}-${CONFIG_TYPE}" \
  --format value --column id)"
echo "Created subnet for OpenShift machines: ${MACHINES_SUBNET_ID}"
echo ${MACHINES_SUBNET_ID}>${SHARED_DIR}/MACHINES_SUBNET_ID
echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINES_SUBNET_RANGE

# This block only works if the subnet range is a /24
if [[ ${SUBNET_RANGE} != *"/24" ]]; then
    echo "ERROR: The subnet range must be a /24"
    exit 1
fi
ALLOCATION_POOL_COMMON=$(echo ${ALLOCATION_POOL_START} | cut -d '.' -f 1-3)
ALLOCATION_POOL_START_LAST_OCTET=$(echo ${ALLOCATION_POOL_START} | cut -d '.' -f 4)
ALLOCATION_POOL_END_LAST_OCTET=$(echo ${ALLOCATION_POOL_END} | cut -d '.' -f 4)
for i in $(seq $ALLOCATION_POOL_START_LAST_OCTET $ALLOCATION_POOL_END_LAST_OCTET); do
    echo "$ALLOCATION_POOL_COMMON.$i" >> ${SHARED_DIR}/MASTER_IPS
done
cp ${SHARED_DIR}/MASTER_IPS ${SHARED_DIR}/WORKER_IPS

BASTION_NET_ID="$(openstack network create --format value --column id \
  --description "Bastion network for ${CLUSTER_NAME}-${CONFIG_TYPE}" \
  "${CLUSTER_NAME}-${CONFIG_TYPE}-bastion-network")"
echo "Created bastion network: ${BASTION_NET_ID}"
echo $BASTION_NET_ID>${SHARED_DIR}/BASTION_NET_ID

BASTION_SUBNET_ID="$(openstack subnet create "${CLUSTER_NAME}-${CONFIG_TYPE}-bastion-subnet" \
    --description "Bastion subnet for ${CLUSTER_NAME}-${CONFIG_TYPE}" \
    --network ${BASTION_NET_ID} \
    --subnet-range ${BASTION_SUBNET_RANGE} \
    --dns-nameserver ${DNS_IP} \
    --format value --column id)"
echo "Created bastion subnet: ${BASTION_SUBNET_ID}"
echo ${BASTION_SUBNET_ID}>${SHARED_DIR}/BASTION_SUBNET_ID

openstack router add subnet ${BASTION_ROUTER_ID} ${BASTION_SUBNET_ID} >/dev/null
echo "Added bastion subnet ${BASTION_SUBNET_ID} to router: ${BASTION_ROUTER_ID}"

echo ${API_VIP}>${SHARED_DIR}/API_IP
echo ${INGRESS_VIP}>${SHARED_DIR}/INGRESS_IP
