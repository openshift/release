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
if [[ "${CONFIG_TYPE}" == "minimal" ]]; then
cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  openstack:
    cloud:            ${OS_CLOUD}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:    ${OPENSTACK_COMPUTE_FLAVOR}
    lbFloatingIP:     ${LB_FIP_IP}
    externalDNS:
      - 1.1.1.1
      - 1.0.0.1
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF

elif [[ "${CONFIG_TYPE}" == "advanced" ]]; then
  cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${BASE_DOMAIN}
compute:
- name: worker
  platform:
    openstack:
EOF
  if [[ -f "${SHARED_DIR}/ADDITIONAL_NETWORK_IDS" ]]; then
    cat >> "${CONFIG}" <<EOF
      additionalNetworkIDs:
EOF
    for NET_ID in $(cat ${SHARED_DIR}/ADDITIONAL_NETWORK_IDS); do
        cat >> "${CONFIG}" << EOF
      - ${NET_ID}
EOF
    done
  else
    cat >> "${CONFIG}" << EOF
     {}
EOF
  fi
  cat >> "${CONFIG}" << EOF
metadata:
  name: ${CLUSTER_NAME}
platform:
  openstack:
    cloud:            ${OS_CLOUD}
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    computeFlavor:    ${OPENSTACK_COMPUTE_FLAVOR}
    lbFloatingIP:     ${LB_FIP_IP}
    externalDNS:
      - 1.1.1.1
      - 1.0.0.1
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