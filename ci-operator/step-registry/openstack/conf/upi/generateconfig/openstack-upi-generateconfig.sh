#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
OS_SUBNET_RANGE=$(<"${SHARED_DIR}/OS_SUBNET_RANGE")
NUMBER_OF_WORKERS=$(<"${SHARED_DIR}/NUMBER_OF_WORKERS")
NUMBER_OF_MASTERS=$(<"${SHARED_DIR}/NUMBER_OF_MASTERS")
OPENSTACK_EXTERNAL_NETWORK=$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")
OPENSTACK_COMPUTE_FLAVOR=$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")
LB_FIP_IP=$(<"${SHARED_DIR}"/LB_FIP_IP)
INGRESS_FIP_IP=$(<"${SHARED_DIR}"/INGRESS_FIP_IP)

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}"/pull-secret)
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}"/ssh-publickey)

CONFIG="${SHARED_DIR}/install-config.yaml"

cat > "${CONFIG}" << EOF
apiVersion: ${CONFIG_API_VERSION}
baseDomain: ${BASE_DOMAIN}
compute:
- hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: ${NUMBER_OF_WORKERS}
controlPlane:
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: ${NUMBER_OF_MASTERS}
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: ${OS_SUBNET_RANGE}
  networkType: ${NETWORK_TYPE}
  serviceNetwork:
  - 172.30.0.0/16
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
