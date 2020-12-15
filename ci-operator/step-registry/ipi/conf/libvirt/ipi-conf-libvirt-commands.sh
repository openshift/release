#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Conf-libvirt"

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
declare -A SUBNETS
  SUBNETS["${CLUSTER_TYPE}-0-0"]="126"
  SUBNETS["${CLUSTER_TYPE}-0-1"]="1"
  SUBNETS["${CLUSTER_TYPE}-0-2"]="2"
  SUBNETS["${CLUSTER_TYPE}-0-3"]="3"
  SUBNETS["${CLUSTER_TYPE}-0-4"]="4"
  SUBNETS["${CLUSTER_TYPE}-1-0"]="126"
  SUBNETS["${CLUSTER_TYPE}-1-1"]="1"
  SUBNETS["${CLUSTER_TYPE}-1-2"]="2"
  SUBNETS["${CLUSTER_TYPE}-1-3"]="3"
  SUBNETS["${CLUSTER_TYPE}-1-4"]="4"

echo "SUBNET=${SUBNETS[${LEASED_RESOURCE}]}"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# get cluster subnet or default it to 126
CLUSTER_SUBNET="${SUBNETS[${LEASED_RESOURCE}]}"
if [[ -z "${CLUSTER_SUBNET}" ]]; then
  CLUSTER_SUBNET=126
fi

declare -A LIBVIRT_HOSTS
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-0-0"]="${REMOTE_LIBVIRT_HOSTNAME}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-0-1"]="${REMOTE_LIBVIRT_HOSTNAME}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-0-2"]="${REMOTE_LIBVIRT_HOSTNAME}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-0-3"]="${REMOTE_LIBVIRT_HOSTNAME}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-0-4"]="${REMOTE_LIBVIRT_HOSTNAME}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-1-0"]="${REMOTE_LIBVIRT_HOSTNAME_1}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-1-1"]="${REMOTE_LIBVIRT_HOSTNAME_1}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-1-2"]="${REMOTE_LIBVIRT_HOSTNAME_1}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-1-3"]="${REMOTE_LIBVIRT_HOSTNAME_1}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-1-4"]="${REMOTE_LIBVIRT_HOSTNAME_1}"

# get cluster libvirt uri or default it the first host
REMOTE_LIBVIRT_URI="qemu+tcp://${LIBVIRT_HOSTS[${LEASED_RESOURCE}]}/system"
if [[ -z "${REMOTE_LIBVIRT_URI}" ]]; then
  REMOTE_LIBVIRT_URI="qemu+tcp://${REMOTE_LIBVIRT_HOSTNAME}/system"
fi
echo "Remote Libvirt=${REMOTE_LIBVIRT_URI}"

NETWORK_NAME="br$(printf ${LEASED_RESOURCE} | tail -c 3)"
CLUSTER_NAME="ocp-${LEASED_RESOURCE}"
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
echo "Network name=$NETWORK_NAME"
echo "Cluster name=$CLUSTER_NAME"
cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${LEASED_RESOURCE}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_REPLICAS}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: 192.168.${CLUSTER_SUBNET}.0/24
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_REPLICAS}
platform:
  libvirt:
    URI: ${REMOTE_LIBVIRT_URI}
    network:
      if: ${NETWORK_NAME}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

cat ${CONFIG}