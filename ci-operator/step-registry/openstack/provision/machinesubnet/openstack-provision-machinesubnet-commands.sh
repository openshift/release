#!/usr/bin/env bash

# This script will create a network, subnet, router, then plug the subnet into that network
# and connect the router to the external networ.
# The resources UUIDs are written in SHARED_DIR.

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != "proxy" ]]; then
    if [[ "$ZONES_COUNT" != "0" ]]; then
      echo "ZONES_COUNT was set to '${ZONES_COUNT}', although CONFIG_TYPE was not set to 'proxy'."
      exit 1
    fi
    echo "Skipping step due to CONFIG_TYPE not being proxy."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
ZONES=$(<"${SHARED_DIR}"/ZONES)

mapfile -t ZONES < <(printf ${ZONES}) >/dev/null
MAX_ZONES_COUNT=${#ZONES[@]}

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

BASTION_ROUTER_ID="$(openstack router create --format value --column id ${ZONES_ARGS} "${CLUSTER_NAME}-${CONFIG_TYPE}-router")"
echo "Created bastion router: ${BASTION_ROUTER_ID}"
echo ${BASTION_ROUTER_ID}>${SHARED_DIR}/BASTION_ROUTER_ID
openstack router set ${BASTION_ROUTER_ID} --external-gateway ${OPENSTACK_EXTERNAL_NETWORK} >/dev/null
echo "Connected bastion router ${BASTION_ROUTER_ID} to external network: ${OPENSTACK_EXTERNAL_NETWORK}"

if [[ ${OPENSTACK_PROVIDER_NETWORK} != "" ]]; then
  if ! openstack network show ${OPENSTACK_PROVIDER_NETWORK} >/dev/null; then
      echo "ERROR: Provider network not found: ${OPENSTACK_PROVIDER_NETWORK}"
      exit 1
  fi
  echo "Provider network detected: ${OPENSTACK_PROVIDER_NETWORK}"
  MACHINES_NET_ID=$(openstack network show -c id -f value "${OPENSTACK_PROVIDER_NETWORK}")
  echo "Provider network ID: ${MACHINES_NET_ID}"
  echo ${MACHINES_NET_ID}>${SHARED_DIR}/MACHINES_NET_ID
  # We assume that a provider network has one subnet attached
  MACHINES_SUBNET_ID=$(openstack network show -c subnets -f value ${OPENSTACK_PROVIDER_NETWORK} | grep -P -o '[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89aAbB][a-f0-9]{3}-[a-f0-9]{12}')
  echo "Provider subnet ID: ${MACHINES_SUBNET_ID}"
  echo ${MACHINES_SUBNET_ID}>${SHARED_DIR}/MACHINES_SUBNET_ID
  SUBNET_RANGE=$(openstack subnet show -c cidr -f value ${MACHINES_SUBNET_ID})
  echo "Provider subnet range: ${SUBNET_RANGE}"
  echo ${SUBNET_RANGE}>${SHARED_DIR}/MACHINES_SUBNET_RANGE

  API_VIP=$(openstack port create --network ${OPENSTACK_PROVIDER_NETWORK} ${CLUSTER_NAME}-${CONFIG_TYPE}-api -c fixed_ips -f value | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)")
  INGRESS_VIP=$(openstack port create --network ${OPENSTACK_PROVIDER_NETWORK} ${CLUSTER_NAME}-${CONFIG_TYPE}-ingress -c fixed_ips -f value | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)")
  echo "API VIP will be ${API_VIP} and Ingress VIP will be ${INGRESS_VIP}"
  echo "These ports should be deleted by openstack-conf-installconfig-commands.sh"
else
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
fi

if [[ "${CONFIG_TYPE}" == "proxy" || ${OPENSTACK_PROVIDER_NETWORK} != "" ]]; then
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
fi

echo ${API_VIP}>${SHARED_DIR}/API_IP
echo ${INGRESS_VIP}>${SHARED_DIR}/INGRESS_IP
