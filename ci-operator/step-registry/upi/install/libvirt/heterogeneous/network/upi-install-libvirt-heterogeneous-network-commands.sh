#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Scan for yq-v4
if ! command -v yq-v4 &> /dev/null; then
  echo "ERROR: yq-v4 could not be found"
  exit 1
fi

# Ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE:-}" ]]; then
  echo "ERROR: Failed to acquire lease"
  exit 1
fi

# Ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "ERROR: Couldn't find lease config file"
  exit 1
fi

# Ensure hostname can be found
HOSTNAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" || "${HOSTNAME}" == "null" ]]; then
  echo "ERROR: Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
VIRSH="mock-nss.sh virsh --connect ${REMOTE_LIBVIRT_URI}"

if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi

if [[ ! -f "${SHARED_DIR}/network.xml" ]]; then
  echo "ERROR: Missing ${SHARED_DIR}/network.xml"
  exit 1
fi

echo "Defining and starting libvirt network ${CLUSTER_NAME} on primary hypervisor..."

# Clean up any stale network left from a previous run (same lease, failed teardown).
# net-destroy is a no-op if the network is inactive; net-undefine removes the definition.
if ${VIRSH} net-info "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "Stale network ${CLUSTER_NAME} found, removing it before redefine..."
  ${VIRSH} net-destroy "${CLUSTER_NAME}" 2>/dev/null || true
  ${VIRSH} net-undefine "${CLUSTER_NAME}"
fi

${VIRSH} net-define "${SHARED_DIR}/network.xml"
${VIRSH} net-autostart "${CLUSTER_NAME}"
${VIRSH} net-start "${CLUSTER_NAME}"

echo "Libvirt network ${CLUSTER_NAME} successfully started."
