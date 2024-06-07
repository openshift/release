#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${CLUSTER_PROFILE_DIR}/leases")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

# ensure pull secret file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "Couldn't find pull secret file"
  exit 1
fi

# ensure ssh key file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  echo "Couldn't find ssh public-key file"
  exit 1
fi

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"

# Default UPI installation
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: "${BASE_DOMAIN}"
metadata:
  name: "${CLUSTER_NAME}"
controlPlane:
  architecture: "${ARCH}"
  hyperthreading: Enabled
  name: master
  replicas: ${CONTROL_COUNT}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: "192.168.$(leaseLookup "subnet").0/24"
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
compute:
- architecture: "${ARCH}"
  hyperthreading: Enabled
  name: worker
  replicas: ${COMPUTE_COUNT}
platform:
  none: {}
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	cat >> "${SHARED_DIR}/install-config.yaml" << EOF
fips: true
EOF
fi