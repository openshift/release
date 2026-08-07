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
EXTERNAL_IP="$(cat "${CLUSTER_PROFILE_DIR}/external_ip")"
if [[ -z "${EXTERNAL_IP}" ]]; then
  echo "Couldn't retrieve external ip from cluster profile"
  exit 1
fi

echo "Gathering hostname..."
HOSTNAME="$(leaseLookup 'hostname')"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"

echo "LEASED_RESOURCE=${LEASED_RESOURCE}"
echo "EXTERNAL_IP=${EXTERNAL_IP}"
echo "HOSTNAME=${HOSTNAME}"
echo "REMOTE_LIBVIRT_URI=${REMOTE_LIBVIRT_URI}"

echo "Beginning connectivity test of the SSP s390x VPN environment..."

# #CHECK
# for rehearsals fast loop
# switch to 4h later ?
attempts=10
sleep_seconds=30
for ((i=1; i<=attempts; i++)); do
  echo "$(date +%H:%M:%S) attempt ${i}/${attempts}"
  # #CHECK: Port 7001 is from #72780
  # Confirm we expose the same
  if curl -s "${EXTERNAL_IP}:7001" >/dev/null \
    && curl -s "${HOSTNAME}:7001" >/dev/null \
    && mock-nss.sh virsh -c "${REMOTE_LIBVIRT_URI}" list >/dev/null; then
    echo "$(date +%H:%M:%S) connectivity ok"
    echo "Ending test of the SSP s390x VPN environment..."
    exit 0
  fi
  if [[ "${i}" -lt "${attempts}" ]]; then
    sleep "${sleep_seconds}"
  fi
done

echo "Connectivity check failed after ${attempts} attempts"
exit 1
