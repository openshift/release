#!/bin/bash

# Heterogeneous-only cleanup for the additional-architecture hypervisor.
# Does not modify the shared upi-libvirt-cleanup-{pre,post} used by homogeneous VPN jobs.

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
if [[ ! -f "${LEASE_CONF}" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

HOSTNAME_CP="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${LEASE_CONF}")"

# Prefer generic key, then arch-specific fallbacks.
HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-additional\"" "${LEASE_CONF}")"
if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
  HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-amd64\"" "${LEASE_CONF}")"
fi
if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
  HOSTNAME_ADDITIONAL="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".\"hostname-s390x\"" "${LEASE_CONF}")"
fi

if [[ -z "${HOSTNAME_ADDITIONAL}" || "${HOSTNAME_ADDITIONAL}" == "null" ]]; then
  echo "No additional-architecture hostname in leases; nothing to clean"
  exit 0
fi

if [[ "${HOSTNAME_ADDITIONAL}" == "${HOSTNAME_CP}" ]]; then
  echo "Additional hostname matches control-plane hostname; shared cleanup already covers it"
  exit 0
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME_ADDITIONAL}/system"
VIRSH="mock-nss.sh virsh --connect ${REMOTE_LIBVIRT_URI}"
echo "Cleaning additional-architecture hypervisor ${REMOTE_LIBVIRT_URI}"

mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" list

set +e

for DOMAIN in $(${VIRSH} list --all --name | grep "${LEASED_RESOURCE}" || true); do
  ${VIRSH} destroy "${DOMAIN}"
  sleep 1s
  ${VIRSH} undefine "${DOMAIN}"
done

if [[ -n "$(${VIRSH} pool-list | grep ${POOL_NAME} || true)" ]]; then
  for VOLUME in $(${VIRSH} vol-list --pool "${POOL_NAME}" | grep "${LEASED_RESOURCE}" | awk '{ print $1 }' || true); do
    ${VIRSH} vol-delete --pool "${POOL_NAME}" "${VOLUME}"
  done
fi

set -e
echo "Additional-architecture cleanup complete for ${HOSTNAME_ADDITIONAL}"
