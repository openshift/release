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

# ensure pull secret file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "Couldn't find pull secret file"
  exit 1
fi

# ensure ssh key file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh_key" ]]; then
  echo "Couldn't find ssh_key files"
  exit 1
fi

PULL_SECRET=$(cat ${CLUSTER_PROFILE_DIR}/pull-secret)
SSH_KEY=$(cat ${CLUSTER_PROFILE_DIR}/ssh-key)
BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"

if [[ ${UPI_INSTALL_TYPE} == 'agent' ]]; then
    echo "placeholder for abi work"
else  # install type is any other form of UPI installation
    # Properly unload the variables for the following install-config
    cat >> "${SHARED_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: "${BASE_DOMAIN}"
metadata:
  name: "${CLUSTER_NAME}"
controlPlane:
  architecture: "${ARCH}"
  hyperthreading: Enabled
  name: master
  replicas: ${CONTROL_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: "192.168.${SUBNET}.0/24"
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
compute:
- architecture: "${ARCH}"
  hyperthreading: Enabled
  name: worker
  replicas: ${COMPUTE_REPLICAS}
platform:
  none: {}
pullSecret: ${PULL_SECRET}
sshKey: ${SSH_KEY}
EOF
    # Generate / output the ignition configs
    # TODO: extract the openshift-install binary, or locate one I can use?
    openshift-install create ignition-configs --dir ${SHARED_DIR}/${WORKDIR}
fi