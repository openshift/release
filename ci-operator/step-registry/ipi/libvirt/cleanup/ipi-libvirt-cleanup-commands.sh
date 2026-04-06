#!/bin/bash

# mikefarah/yq v4 is installed as yq-v4 in current libvirt-installer images; older images (e.g. OCP 4.8) ship only "yq".
if command -v yq-v4 >/dev/null 2>&1; then
  YQ=yq-v4
elif command -v yq >/dev/null 2>&1; then
  YQ=yq
else
  echo "Neither yq-v4 nor yq found in PATH"
  exit 1
fi

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

# ensure hostname can be found
HOSTNAME="$("${YQ}" -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for $REMOTE_LIBVIRT_URI"

# Test the remote connection
echo "Scanning for resources in the remote environment:"
echo "--  Domains --"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list --all --name
echo "--  Pools --"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} pool-list --all --name
echo "--  Networks --"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-list --all --name

set +e

# Remove conflicting domains
for DOMAIN in $(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" destroy "${DOMAIN}"
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" undefine "${DOMAIN}"
done

# Remove conflicting pools
for POOL in $(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" pool-list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" pool-destroy "${POOL}"
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" pool-delete "${POOL}"
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" pool-undefine "${POOL}"
done

# Remove conflicting networks
for NET in $(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-destroy "${NET}"
  mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-undefine "${NET}"
done

# Detect conflicts
CONFLICTING_DOMAINS=$(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" list --all --name | grep "${LEASED_RESOURCE}")
CONFLICTING_POOLS=$(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" pool-list --all --name | grep "${LEASED_RESOURCE}")
CONFLICTING_NETWORKS=$(mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-list --all --name | grep "${LEASED_RESOURCE}")

set -e

if [ ! -z "$CONFLICTING_DOMAINS" ] || [ ! -z "$CONFLICTING_POOLS" ] || [ ! -z "$CONFLICTING_NETWORKS" ]; then
  echo "Could not ensure clean state for lease ${LEASED_RESOURCE}. Found conflicting resources."
  echo "Conflicting domains: $CONFLICTING_DOMAINS"
  echo "Conflicting pools: $CONFLICTING_POOLS"
  echo "Conflicting networks: $CONFLICTING_NETWORKS"
  exit 1
fi