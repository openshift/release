#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Scan for yq-v4
if ! command -v yq-v4 &> /dev/null
then
    echo "yq-v4 could not be found"
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

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
# shellcheck source=../../../libvirt/cluster-context/upi-libvirt-cluster-context-commands.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../libvirt/cluster-context" && pwd)/upi-libvirt-cluster-context-commands.sh"
upi_libvirt_cluster_context_init
leaseLookup() { upi_libvirt_cluster_lease_lookup "$1"; }

HOSTNAME="$(leaseLookup 'hostname')"
REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for $REMOTE_LIBVIRT_URI (${CLUSTER_NAME})"

echo "Active networks pre creation:"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-list

echo "Printing network xml to be created:"
cat "${CLUSTER_WORK_DIR}/network.xml"

echo "Creating the libvirt network..."
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-define "${CLUSTER_WORK_DIR}/network.xml"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-autostart "${CLUSTER_NAME}"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-start "${CLUSTER_NAME}"

echo "Active networks post creation:"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-list
