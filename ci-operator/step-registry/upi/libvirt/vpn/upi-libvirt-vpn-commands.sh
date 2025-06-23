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

EXTERNAL_IP="$(cat ${CLUSTER_PROFILE_DIR}/external_ip)"

LEASE_PORT="$(leaseLookup 'lease_port')"
if [[ -z "${LEASE_PORT}" ]]; then
  echo "Couldn't retrieve port from lease config"
  exit 1
fi

echo "Beginning test of the Z Network environment...\n"

echo "LEASE_CONF=${LEASE_CONF}"
echo "EXTERNAL_IP=${EXTERNAL_IP}"
echo "LEASE_PORT=${LEASE_PORT}"

echo "curl http://${EXTERNAL_IP}:${LEASE_PORT}"

echo "Ending test of the Z Network environment..."