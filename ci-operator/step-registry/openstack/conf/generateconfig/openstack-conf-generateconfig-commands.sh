#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
OPENSTACK_COMPUTE_FLAVOR="${OPENSTACK_COMPUTE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")}"

LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)
INGRESS_FIP_IP=$(<"${SHARED_DIR}"/INGRESS_FIP_IP)

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

CONFIG="${SHARED_DIR}/install-config.yaml"
if [[ "${CONFIG_TYPE}" == "minimal" ]]; then
cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: ${NETWORK_TYPE}
platform:
  openstack:
    cloud:             ${OS_CLOUD}
    externalNetwork:   ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:     ${OPENSTACK_COMPUTE_FLAVOR}
    lbFloatingIP:      ${LB_FIP_IP}
    ingressFloatingIP: ${INGRESS_FIP_IP}
    externalDNS:
      - 1.1.1.1
      - 1.0.0.1
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
else
    echo "No valid install config type specified. Please check CONFIG_TYPE"
    exit 1
fi

# Lets  check the syntax of yaml file by reading it.
python -c 'import yaml;
import sys;
data = yaml.safe_load(open(sys.argv[1]))' "${SHARED_DIR}/install-config.yaml"
