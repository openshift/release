#!/usr/bin/env bash

# This script remove a network and a router.

set -o nounset
set -o errexit
set -o pipefail

if [[ "$CONFIG_TYPE" != "proxy" ]]; then
    echo "Skipping step due to CONFIG_TYPE not being proxy."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml

CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

>&2 echo "Starting the network cleanup for cluster name $CLUSTER_NAME"
if [[ -f ${SHARED_DIR}"/BASTION_ROUTER_ID" ]]; then
  BASTION_ROUTER_ID=$(<"${SHARED_DIR}"/BASTION_ROUTER_ID)
  if [[ -f ${SHARED_DIR}"/BASTION_SUBNET_ID" ]]; then
      BASTION_SUBNET_ID=$(<"${SHARED_DIR}"/BASTION_SUBNET_ID)
      openstack router remove subnet ${BASTION_ROUTER_ID} ${BASTION_SUBNET_ID} || >&2 echo "Failed to delete bastion subnet ${BASTION_SUBNET_ID} from bastion router ${BASTION_ROUTER_ID}"
  fi
  # We want to remove the machines subnet from the router when:
  # * there is a machine subnet that was created
  # * we don't use a provider network for the machines since this network isn't connected to a neutron router
  # * when the network is not isolated, like it's the case in "proxy" CONFIG_TYPE
  if [[ -f ${SHARED_DIR}"/MACHINES_SUBNET_ID" && ${OPENSTACK_PROVIDER_NETWORK} == "" && ${CONFIG_TYPE} != "proxy" ]]; then
    MACHINES_SUBNET_ID=$(<"${SHARED_DIR}"/MACHINES_SUBNET_ID)
    openstack router remove subnet ${BASTION_ROUTER_ID} ${MACHINES_SUBNET_ID} || >&2 echo "Failed to delete machines subnet ${MACHINES_SUBNET_ID} from bastion router ${BASTION_ROUTER_ID}"
  fi
  openstack router delete ${BASTION_ROUTER_ID} || >&2 echo "Failed to delete bastion router ${BASTION_ROUTER_ID}"
fi
if [[ -f ${SHARED_DIR}"/BASTION_NET_ID" ]]; then
  NET_ID=$(<"${SHARED_DIR}"/BASTION_NET_ID)
  openstack network delete ${NET_ID} || >&2 echo "Failed to delete bastion network ${NET_ID}"
fi

if [[ -f ${SHARED_DIR}"/MACHINES_NET_ID" && ${OPENSTACK_PROVIDER_NETWORK} == "" ]]; then
  NET_ID=$(<"${SHARED_DIR}"/MACHINES_NET_ID)
  openstack network delete ${NET_ID} || >&2 echo "Failed to delete machines network ${NET_ID}"
fi

for p in api ingress; do
  if openstack port show ${CLUSTER_NAME}-${CONFIG_TYPE}-${p} >/dev/null; then
    echo "Leftover port exists: ${CLUSTER_NAME}-${CONFIG_TYPE}-${p}, probably due to a failure before install, removing it"
    openstack port delete ${CLUSTER_NAME}-${CONFIG_TYPE}-${p} || >&2 echo "Failed to delete port ${CLUSTER_NAME}-${CONFIG_TYPE}-${p}"
  fi
done

>&2 echo 'Cleanup done.'
