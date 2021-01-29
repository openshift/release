#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

#Read necessary variables
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

CONFIG="${SHARED_DIR}/install-config.yaml"

case "$CLUSTER_TYPE" in
  openstack-vexxhost)
      OPENSTACK_EXTERNAL_NETWORK="external"
      OPENSTACK_INSTANCE_FLAVOR="m1.s2.xlarge"
      CONFIG_API_VERSION="v1beta4"
    ;;
  openstack)
      OPENSTACK_EXTERNAL_NETWORK="external"
      OPENSTACK_INSTANCE_FLAVOR="m1.s2.xlarge"
      CONFIG_API_VERSION="v1beta4"
    ;;
esac



if [[ "${CONFIG_TYPE}" == "minimal" ]]; then
cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  openstack:
    cloud:            ${CLUSTER_TYPE}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:    ${OPENSTACK_INSTANCE_FLAVOR}
    lbFloatingIP:     ${LB_FIP_IP}
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
else
    echo "NO valid install config type specified. Please check  CONFIG_TYPE"
    exit 1
fi

# Lets  check the syntax of yaml file by reading it.
python -c 'import yaml;
import sys;
data = yaml.safe_load(open(sys.argv[1]))' ${SHARED_DIR}/install-config.yaml