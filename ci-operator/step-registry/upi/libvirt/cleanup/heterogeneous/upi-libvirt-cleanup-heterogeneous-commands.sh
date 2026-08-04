#!/bin/bash

# Heterogeneous-only cleanup for the additional-architecture hypervisor.
# Does not modify the shared upi-libvirt-cleanup-{pre,post} used by homogeneous VPN jobs.

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${LEASED_RESOURCE:-}" ]]; then
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
VIRSH=(mock-nss.sh virsh --connect "${REMOTE_LIBVIRT_URI}")
echo "Cleaning additional-architecture hypervisor ${REMOTE_LIBVIRT_URI}"

"${VIRSH[@]}" list

# Domains/volumes are named worker-hetero-<n>-${LEASED_RESOURCE}[.qcow2].
# Match on the install naming delimiter as a suffix to avoid substring hits
# (e.g. lease "foo" matching "foo2") and regex metacharacters in lease IDs.
owned_domain() {
  [[ "${1}" == *"-${LEASED_RESOURCE}" ]]
}

owned_volume() {
  [[ "${1}" == *"-${LEASED_RESOURCE}.qcow2" || "${1}" == *"-${LEASED_RESOURCE}" ]]
}

while IFS= read -r DOMAIN; do
  [[ -z "${DOMAIN}" ]] && continue
  owned_domain "${DOMAIN}" || continue
  # destroy/undefine are expected no-ops when the domain is already gone.
  "${VIRSH[@]}" destroy "${DOMAIN}" || true
  sleep 1s
  "${VIRSH[@]}" undefine "${DOMAIN}" || true
done < <("${VIRSH[@]}" list --all --name)

POOLS="$("${VIRSH[@]}" pool-list --all --name)"
if printf '%s\n' "${POOLS}" | grep -Fxq -- "${POOL_NAME}"; then
  while IFS= read -r VOLUME; do
    [[ -z "${VOLUME}" || "${VOLUME}" == "Name" ]] && continue
    owned_volume "${VOLUME}" || continue
    "${VIRSH[@]}" vol-delete --pool "${POOL_NAME}" "${VOLUME}" || true
  done < <("${VIRSH[@]}" vol-list --pool "${POOL_NAME}" | awk '{ print $1 }')
fi

echo "Additional-architecture cleanup complete for ${HOSTNAME_ADDITIONAL}"
