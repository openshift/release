#!/bin/bash

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

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"

# Primary Z hostname is required. hostname-amd64 is optional (heterogeneous VPN leases).
HOSTNAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${LEASE_CONF}")"
if [[ -z "${HOSTNAME}" || "${HOSTNAME}" == "null" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

HOSTNAME_AMD64="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-amd64\"" "${LEASE_CONF}")"
HOSTNAMES=("${HOSTNAME}")
if [[ -n "${HOSTNAME_AMD64}" && "${HOSTNAME_AMD64}" != "null" && "${HOSTNAME_AMD64}" != "${HOSTNAME}" ]]; then
  HOSTNAMES+=("${HOSTNAME_AMD64}")
fi

cleanup_host () {
  local host="$1"
  local REMOTE_LIBVIRT_URI="qemu+tcp://${host}/system"
  local VIRSH="mock-nss.sh virsh --connect ${REMOTE_LIBVIRT_URI}"
  echo "Using libvirt connection for $REMOTE_LIBVIRT_URI"

  # Test the remote connection
  mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list

  set +e

  # Remove stale domains
  echo "Removing stale domains on ${host}..."
  for DOMAIN in $(${VIRSH} list --all --name | grep "${LEASED_RESOURCE}")
  do
    ${VIRSH} destroy "${DOMAIN}"
    sleep 1s
    ${VIRSH} undefine "${DOMAIN}"
  done

  # Remove stale volumes
  echo "Removing stale ci pool volumes on ${host}..."
  if [[ ! -z "$(${VIRSH} pool-list | grep ${POOL_NAME})" ]]; then
    for VOLUME in $(${VIRSH} vol-list --pool ${POOL_NAME} | grep "${LEASED_RESOURCE}" | awk '{ print $1 }')
    do
      ${VIRSH} vol-delete --pool ${POOL_NAME} ${VOLUME}
    done
  fi

  # Remove stale httpd volumes
  echo "Removing stale httpd volumes on ${host}..."
  if [[ ! -z "$(${VIRSH} pool-list | grep ${HTTPD_POOL_NAME})" ]]; then
    for VOLUME in $(${VIRSH} vol-list --pool ${HTTPD_POOL_NAME} | grep "${LEASED_RESOURCE}" | awk '{ print $1 }')
    do
      ${VIRSH} vol-delete --pool ${HTTPD_POOL_NAME} ${VOLUME}
    done
  fi

  echo "Removing obsolete source volume on ${host}..."
  SOURCE_VOLUME=$(${VIRSH} vol-list --pool ${POOL_NAME} | awk '{ print $1 }' | grep -E '^rhcos' || true)
  if [[ ! -z "${SOURCE_VOLUME}" ]]; then
    ${VIRSH} vol-delete --pool ${POOL_NAME} "${SOURCE_VOLUME}"
  fi

  echo "Removing obsolete pools on ${host}..."
  for POOL in $(${VIRSH} pool-list --all --name | grep "${LEASED_RESOURCE}")
  do
    ${VIRSH} pool-destroy "${POOL}"
    ${VIRSH} pool-delete "${POOL}"
    ${VIRSH} pool-undefine "${POOL}"
  done

  # Remove conflicting networks
  echo "Removing stale networks on ${host}..."
  for NET in $(${VIRSH} net-list --all --name | grep "${LEASED_RESOURCE}")
  do
    ${VIRSH} net-destroy "${NET}"
    ${VIRSH} net-undefine "${NET}"
  done

  # Detect conflicts
  CONFLICTING_DOMAINS=$(${VIRSH} list --all --name | grep "${LEASED_RESOURCE}")
  CONFLICTING_VOLUMES=$(${VIRSH} vol-list --pool ${POOL_NAME} | grep -E "${LEASED_RESOURCE}-(bootstrap|master|worker|compute|control)" | awk '{ print $1 }' || true)
  STALE_IPI_VOLUMES=$(${VIRSH} vol-list --pool ${POOL_NAME} | grep "${LEASED_RESOURCE}" | grep -Ev "(bootstrap|master|worker|compute|control)" | awk '{ print $1 }' || true)
  CONFLICTING_POOLS=$(${VIRSH} pool-list --all --name | grep "${LEASED_RESOURCE}")
  CONFLICTING_NETWORKS=$(${VIRSH} net-list --all --name | grep "${LEASED_RESOURCE}")

  set -e

  echo "Checking for remaining resource conflicts on ${host}..."
  if [ ! -z "${CONFLICTING_DOMAINS}" ] || [ ! -z "${CONFLICTING_VOLUMES}" ] || [ ! -z "${CONFLICTING_POOLS}" ] || [ ! -z "${CONFLICTING_NETWORKS}" ]; then
    echo "Could not ensure clean state for lease ${LEASED_RESOURCE} on ${host}"
    echo "Conflicting domains: $CONFLICTING_DOMAINS"
    echo "Conflicting volumes: $CONFLICTING_VOLUMES"
    echo "Conflicting pools: $CONFLICTING_POOLS"
    echo "Conflicting networks: $CONFLICTING_NETWORKS"
    exit 1
  fi

  if [ ! -z "${STALE_IPI_VOLUMES}" ]; then
    echo "Stale IPI volumes remain on ${host}..."
    echo "Stale volumes: ${STALE_IPI_VOLUMES}"
  fi
}

for host in "${HOSTNAMES[@]}"; do
  cleanup_host "${host}"
done
