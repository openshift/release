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

echo "Gathering hostname..."
HOSTNAME="$(leaseLookup 'hostname')"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://$HOSTNAME/system"

for ((i = 0; i < 24; i++)); do
        curl -s "$EXTERNAL_IP:7001" >/dev/null &&
        curl -s "$HOSTNAME:7001" >/dev/null &&
        mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list >/dev/null
        if [ $? -eq 0 ]; then echo "$(date +%H:%M) ok"; fi
        sleep 600
done

echo "Ending test of the IBM-Z network environment..."
