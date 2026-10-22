#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# curl a lightweight :7001 server on external + internal IP
# Expected body is configured on the OZ web server
#
# Vault (selfservice/libvirt-s390x-vpn-virt/leases): external_ip, internal_ip
EXPECTED_BODY="Hello, the connection is working. Have a nice day!"

echo "Gathering external ip..."
EXTERNAL_IP="$(cat "${CLUSTER_PROFILE_DIR}/external_ip")"
if [[ -z "${EXTERNAL_IP}" ]]; then
  echo "Couldn't retrieve external ip from cluster profile"
  exit 1
fi

echo "Gathering internal ip..."
INTERNAL_IP="$(cat "${CLUSTER_PROFILE_DIR}/internal_ip")"
if [[ -z "${INTERNAL_IP}" ]]; then
  echo "Couldn't retrieve internal ip from cluster profile"
  exit 1
fi

echo "Beginning connectivity test of the SSP s390x VPN environment..."

rc=0
for target in "${EXTERNAL_IP}" "${INTERNAL_IP}"; do
  echo "$(date +%H:%M:%S) curling ${target}:7001"
  # avoid leaking env details
  if ! body="$(curl -fsS --connect-timeout 10 --max-time 20 "http://${target}:7001/")"; then
    echo "$(date +%H:%M:%S) curl failed for target"
    rc=1
    continue
  fi
  if [[ "${body}" != *"${EXPECTED_BODY}"* ]]; then
    echo "$(date +%H:%M:%S) unexpected response body for target"
    rc=1
    continue
  fi
  echo "$(date +%H:%M:%S) ok for target"
done

if [[ "${rc}" -eq 0 ]]; then
  echo "$(date +%H:%M:%S) connectivity ok"
else
  echo "$(date +%H:%M:%S) connectivity check failed"
fi

# Temporary debug window so we can `oc rsh` / inspect the pod during rehearsals
# Remove once the lane is stable
echo "Sleeping 20m for debug window..."
sleep 20m

echo "Ending test of the SSP s390x VPN environment..."
exit "${rc}"
