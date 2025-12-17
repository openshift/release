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

echo "Gathering hostname ..."
HOSTNAME="$(leaseLookup 'hostname')"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

echo "Test the host connection..."
curl -q "$EXTERNAL_IP:7001"
curl -q "$HOSTNAME:7001"

echo "Test the libvirt connection..."
REMOTE_LIBVIRT_URI="qemu+tcp://$HOSTNAME/system"
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list

sleep 1200

echo "Ending test of the IBMZ Network environment..."
