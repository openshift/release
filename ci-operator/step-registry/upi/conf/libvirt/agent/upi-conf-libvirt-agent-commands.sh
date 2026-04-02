#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# OCP 4.x libvirt-installer images may not ship yq-v4; install on demand.
if ! command -v yq-v4 &>/dev/null; then
  if [ ! -f /tmp/yq-v4 ]; then
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
      -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  fi
  export PATH="/tmp:${PATH}"
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