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

# Must match upi-conf-libvirt install-config naming when USE_EXTERNAL_DNS is true (VPN / phc-cicd).
if [ "${USE_EXTERNAL_DNS:-false}" == "true" ]; then
  BASE_DOMAIN="phc-cicd.cis.ibm.net"
  CLUSTER_NAME="${LEASED_RESOURCE}"
else
  BASE_DOMAIN="${LEASED_RESOURCE}.ci"
  CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
fi
BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"

CONTROL_COUNT="${CONTROL_COUNT:-3}"
COMPUTE_COUNT="${COMPUTE_COUNT:-2}"
ARBITER_COUNT="${ARBITER_COUNT:-0}"

echo "Creating the agent-config.yaml file..."
# TNA: CONTROL_COUNT=2 ARBITER_COUNT=1 (optional COMPUTE_COUNT workers).
# SNO: CONTROL_COUNT=1 COMPUTE_COUNT=0 ARBITER_COUNT=0.
# Existing HA agent jobs leave counts unset and keep 3+2.
if [[ "${ARBITER_COUNT}" -gt 0 ]]; then
  if [[ "${CONTROL_COUNT}" -lt 2 ]]; then
    echo "ERROR: ARBITER_COUNT=${ARBITER_COUNT} requires CONTROL_COUNT>=2 (got ${CONTROL_COUNT})" >&2
    exit 1
  fi
  if [[ "${ARBITER_COUNT}" -gt 1 ]]; then
    echo "ERROR: ARBITER_COUNT must be 0 or 1 (got ${ARBITER_COUNT})" >&2
    exit 1
  fi

  {
    cat << EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: 192.168.$(leaseLookup "subnet").10
hosts:
EOF
    for (( i=0; i<CONTROL_COUNT; i++ )); do
      cat << EOF
  - hostname: control-${i}.${BASE_URL}
    role: master
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup "\"control-plane\"[${i}].mac")
EOF
    done
    for (( i=0; i<ARBITER_COUNT; i++ )); do
      lease_idx=$((CONTROL_COUNT + i))
      cat << EOF
  - hostname: arbiter-${i}.${BASE_URL}
    role: arbiter
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup "\"control-plane\"[${lease_idx}].mac")
EOF
    done
    for (( i=0; i<COMPUTE_COUNT; i++ )); do
      cat << EOF
  - hostname: compute-${i}.${BASE_URL}
    role: worker
    interfaces:
      - name: enc1
        macAddress: $(leaseLookup "compute[${i}].mac")
EOF
    done
  } >> "${SHARED_DIR}/agent-config.yaml"
elif [ "${CONTROL_COUNT}" = "1" ] && [ "${COMPUTE_COUNT}" = "0" ]; then
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
EOF
else
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
fi

cat "${SHARED_DIR}/agent-config.yaml"
