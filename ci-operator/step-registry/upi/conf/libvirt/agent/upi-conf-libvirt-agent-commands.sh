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
function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Creating the agent-config.yaml file..."
cat >> "${SHARED_DIR}/agent-config.yaml" << EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: 192.168.$(leaseLookup "subnet").10
hosts:
  - hostname: control-0.${BASE_URL}
    role: master
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup '"control-plane"[0].mac')
  - hostname: control-1.${BASE_URL}
    role: master
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup '"control-plane"[1].mac')
  - hostname: control-2.${BASE_URL}
    role: master
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup '"control-plane"[2].mac')
  - hostname: compute-0.${BASE_URL}
    role: worker
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup 'compute[0].mac')
  - hostname: compute-1.${BASE_URL}
    role: worker
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup 'compute[1].mac')
EOF

cat "${SHARED_DIR}/agent-config.yaml"