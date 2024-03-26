#!/bin/bash

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

# ensure hostname can be found
HOSTNAME="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for $REMOTE_LIBVIRT_URI"

# Test the remote connection
echo "Active networks pre creation:"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-list

# Show network xml
echo "Printing network xml to be created:"
cat "${SHARED_DIR}/network.xml"

# Create the libvirt network
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-define "${SHARED_DIR}/network.xml"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-autostart "${CLUSTER_NAME}"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-start "${CLUSTER_NAME}"

# Show created network
echo "Active networks post creation:"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} net-list