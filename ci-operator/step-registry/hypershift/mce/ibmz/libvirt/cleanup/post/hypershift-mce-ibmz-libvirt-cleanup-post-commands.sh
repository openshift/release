#!/bin/bash

set -euo pipefail

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

cleanup_lease_resources() {
  local lease_name="${1}"
  local suffix="${2}"
  local prefix="${lease_name}${suffix}"

  HOSTNAME="$(yq-v4 -oy ".\"${lease_name}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
  if [[ -z "${HOSTNAME}" ]]; then
    echo "Couldn't retrieve hostname for lease ${lease_name}"
    return 1
  fi

  REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
  VIRSH="mock-nss.sh virsh --connect ${REMOTE_LIBVIRT_URI}"
  echo "Post-cleaning libvirt resources for prefix ${prefix} on ${REMOTE_LIBVIRT_URI}"

  set +e
  for DOMAIN in $(${VIRSH} list --all --name | grep "${prefix}" || true); do
    ${VIRSH} destroy "${DOMAIN}" || true
    ${VIRSH} undefine "${DOMAIN}" || true
  done

  if [[ -n "$(${VIRSH} pool-list | grep ${POOL_NAME} || true)" ]]; then
    for VOLUME in $(${VIRSH} vol-list --pool ${POOL_NAME} | grep "${prefix}" | awk '{ print $1 }' || true); do
      ${VIRSH} vol-delete --pool ${POOL_NAME} "${VOLUME}" || true
    done
  fi

  if [[ -n "$(${VIRSH} pool-list | grep ${HTTPD_POOL_NAME} || true)" ]]; then
    for VOLUME in $(${VIRSH} vol-list --pool ${HTTPD_POOL_NAME} | grep "${prefix}" | awk '{ print $1 }' || true); do
      ${VIRSH} vol-delete --pool ${HTTPD_POOL_NAME} "${VOLUME}" || true
    done
  fi

  for NET in $(${VIRSH} net-list --all --name | grep "${prefix}" || true); do
    ${VIRSH} net-destroy "${NET}" || true
    ${VIRSH} net-undefine "${NET}" || true
  done
  set -e
}

cleanup_lease_resources "${LEASED_RESOURCE}" "-mgmt"
cleanup_lease_resources "${LEASED_RESOURCE}" "-infra"

if [[ -n "${INFRA_LEASED_RESOURCE:-}" ]]; then
  cleanup_lease_resources "${INFRA_LEASED_RESOURCE}" "-infra"
fi
