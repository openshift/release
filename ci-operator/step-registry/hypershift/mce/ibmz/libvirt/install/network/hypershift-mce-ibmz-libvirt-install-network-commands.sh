#!/bin/bash

if ! command -v yq-v4 &> /dev/null; then
  echo "yq-v4 could not be found"
  exit 1
fi

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/hypershift-mce-ibmz-libvirt-common.sh
source "${SCRIPT_DIR}/../../common/hypershift-mce-ibmz-libvirt-common.sh"

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
cluster_libvirt_init
leaseLookup() { cluster_libvirt_lease_lookup "$1"; }

HOSTNAME="$(leaseLookup 'hostname')"
REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for ${REMOTE_LIBVIRT_URI} (${CLUSTER_ROLE} cluster)"

echo "Active networks pre creation:"
mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-list

echo "Printing network xml to be created:"
cat "${CLUSTER_DIR}/network.xml"

echo "Creating the libvirt network for ${CLUSTER_NAME}..."
mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-define "${CLUSTER_DIR}/network.xml"
mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-autostart "${CLUSTER_NAME}"
mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-start "${CLUSTER_NAME}"

echo "Active networks post creation:"
mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" net-list
