#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

echo "Gathering external ip..."
EXTERNAL_IP="$(cat ${CLUSTER_PROFILE_DIR}/external_ip)"
if [[ -z "${EXTERNAL_IP}" ]]; then
  echo "Couldn't retrieve external ip from lease config"
  exit 1
fi

echo "Gathering lease port..."
LEASE_PORT="$(leaseLookup 'lease_port')"
if [[ -z "${LEASE_PORT}" ]]; then
  echo "Couldn't retrieve port from lease config"
  exit 1
fi

echo "Test the libvirt connection..."
REMOTE_LIBVIRT_URI_1="qemu+tcp://10.0.1.2/system"
REMOTE_LIBVIRT_URI_2="qemu+tcp://10.0.1.2:16509/system"
echo "No port specified..."
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI_1} list
echo "Include the port..."
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI_2} list

echo "Ending test of the Z Network environment..."