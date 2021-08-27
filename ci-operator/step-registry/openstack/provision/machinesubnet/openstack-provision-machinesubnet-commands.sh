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
ZONES=$(<"${SHARED_DIR}"/ZONES)

mapfile -t ZONES < <(printf ${ZONES}) >/dev/null
MAX_ZONES_COUNT=${#ZONES[@]}

# For now, we only support the deployment of OCP into specific availability zones when pre-configuring
# the network (BYON), for known limitations that will be addressed in the future.
if [[ "$CONFIG_TYPE" != "byon" ]]; then
    if [[ "$ZONES_COUNT" != "0" ]]; then
        echo "ZONES_COUNT was set to '${ZONES_COUNT}', although CONFIG_TYPE was not set to 'byon'."
        exit 1
    fi

    echo "Skipping step due to CONFIG_TYPE not being byon."
    exit 0
fi

if [[ ${ZONES_COUNT} -gt ${MAX_ZONES_COUNT} ]]; then
  echo "Too many zones were requested: ${ZONES_COUNT}; only ${MAX_ZONES_COUNT} are available: ${ZONES[*]}"
  exit 1
fi

if [[ "${ZONES_COUNT}" == "0" ]]; then
  ZONES_ARGS=""
elif [[ "${ZONES_COUNT}" == "1" ]]; then
  for ((i=0; i<${MAX_ZONES_COUNT}; ++i )) ; do
    ZONES_ARGS+="--availability-zone-hint ${ZONES[$i]} "
  done
else
  # For now, we only support a cluster within a single AZ.
  # This will change in the future.
  echo "Wrong ZONE_COUNT, can only be 0 or 1, got ${ZONES_COUNT}"
  exit 1
fi

NET_ID="$(openstack network create --format value --column id "${CLUSTER_NAME}-network")"
echo "Created network: ${NET_ID}"
echo $NET_ID>${SHARED_DIR}/BASTIONSUBNET_NET_ID

SUBNET_ID="$(openstack subnet create "${CLUSTER_NAME}-subnet" \
    --network ${NET_ID} \
    --subnet-range ${SUBNET_RANGE} \
    --dns-nameserver ${DNS_IP} \
    --allocation-pool start=${ALLOCATION_POOL_START},end=${ALLOCATION_POOL_END} \
    --format value --column id)"
echo "Created subnet: ${SUBNET_ID}"
echo ${SUBNET_ID}>${SHARED_DIR}/BASTIONSUBNET_SUBNET_ID

ROUTER_ID="$(openstack router create --format value --column id ${ZONES_ARGS} "${CLUSTER_NAME}-router")"
echo "Created router: ${ROUTER_ID}"
echo ${ROUTER_ID}>${SHARED_DIR}/BASTIONSUBNET_ROUTER_ID

openstack router add subnet ${ROUTER_ID} ${SUBNET_ID} >/dev/null
echo "Added subnet ${SUBNET_ID} to router: ${ROUTER_ID}"

openstack router set ${ROUTER_ID} --external-gateway ${OPENSTACK_EXTERNAL_NETWORK} >/dev/null
echo "Connected router ${ROUTER_ID} to external network: ${OPENSTACK_EXTERNAL_NETWORK}"

if [[ ${OPENSTACK_PROVIDER_NETWORK} != "" ]]; then
    if ! openstack network show ${OPENSTACK_PROVIDER_NETWORK} >/dev/null; then
        echo "ERROR: Provider network not found: ${OPENSTACK_PROVIDER_NETWORK}"
        exit 1
    fi
    echo "Provider network detected: ${OPENSTACK_PROVIDER_NETWORK}"
    NET_ID=$(openstack network show -c id -f value "${OPENSTACK_PROVIDER_NETWORK}")
    echo "Provider network ID: ${NET_ID}"
    # We assume that a provider network has one subnet attached
    SUBNET_ID=$(openstack network show -c subnets -f value ${OPENSTACK_PROVIDER_NETWORK} | grep -P -o '[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89aAbB][a-f0-9]{3}-[a-f0-9]{12}')
    echo ${SUBNET_ID}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_ID
    echo "Provider subnet ID: ${SUBNET_ID}"
    SUBNET_RANGE=$(openstack subnet show -c cidr -f value ${SUBNET_ID})
    echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_RANGE
    echo "Provider subnet range: ${SUBNET_RANGE}"

    API_VIP=$(openstack port create --network ${OPENSTACK_PROVIDER_NETWORK} ${CLUSTER_NAME}-api -c fixed_ips -f value | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)")
    INGRESS_VIP=$(openstack port create --network ${OPENSTACK_PROVIDER_NETWORK} ${CLUSTER_NAME}-ingress -c fixed_ips -f value | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)")
    echo "API VIP will be ${API_VIP} and Ingress VIP will be ${INGRESS_VIP}"
    echo "These ports should be deleted by openstack-conf-generateconfig-commands.sh"
fi

echo ${SUBNET_ID}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_ID
echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINESSUBNET_SUBNET_RANGE
echo ${API_VIP}>${SHARED_DIR}/API_IP
echo ${INGRESS_VIP}>${SHARED_DIR}/INGRESS_IP
