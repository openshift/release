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

echo "Sleeping for 1 hour for manual testing..."
sleep 3600

echo "Beginning test of the Z Network environment..."

echo "curl the hello world page..."
curl http://${EXTERNAL_IP}:${LEASE_PORT}

echo "curl the vpn server ip..."
curl ${EXTERNAL_IP}:${LEASE_PORT}

echo "curl the lpar ip..."
curl 10.0.1.2:${LEASE_PORT}

echo "Ending test of the Z Network environment..."