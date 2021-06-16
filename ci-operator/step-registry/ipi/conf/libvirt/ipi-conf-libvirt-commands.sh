#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

touch ${SHARED_DIR}/cluster-config.yaml
MULTIARCH_RELEASE_IMAGE_INITIAL=registry.ci.openshift.org/ocp-${ARCH}/release-${ARCH}:${BRANCH}
if [[ -n "${MULTIARCH_RELEASE_IMAGE_INITIAL}" ]]; then
  echo "Installing from initial release ${MULTIARCH_RELEASE_IMAGE_INITIAL}"
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${MULTIARCH_RELEASE_IMAGE_INITIAL}"
  yq write --inplace ${SHARED_DIR}/cluster-config.yaml OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

openshift-install version

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
  SUBNETS["${CLUSTER_TYPE}-2-0"]="126"
  SUBNETS["${CLUSTER_TYPE}-2-1"]="1"
  SUBNETS["${CLUSTER_TYPE}-2-2"]="2"
  SUBNETS["${CLUSTER_TYPE}-2-3"]="3"
  SUBNETS["${CLUSTER_TYPE}-2-4"]="4"

# Debug echo "SUBNET=${SUBNETS[${LEASED_RESOURCE}]}"

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

# Setting Hostnames
if [[ "${ARCH}" == "s390x" ]]; then
  REMOTE_LIBVIRT_HOSTNAME=lnxocp01
  REMOTE_LIBVIRT_HOSTNAME_1=lnxocp02
  REMOTE_LIBVIRT_HOSTNAME_2=""
elif [[ "${ARCH}" == "ppc64le" ]]; then
  REMOTE_LIBVIRT_HOSTNAME=C155F2U33
  REMOTE_LIBVIRT_HOSTNAME_1=C155F2U31
  REMOTE_LIBVIRT_HOSTNAME_2=C155F2U35
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
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-2-0"]="${REMOTE_LIBVIRT_HOSTNAME_2}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-2-1"]="${REMOTE_LIBVIRT_HOSTNAME_2}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-2-2"]="${REMOTE_LIBVIRT_HOSTNAME_2}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-2-3"]="${REMOTE_LIBVIRT_HOSTNAME_2}"
  LIBVIRT_HOSTS["${CLUSTER_TYPE}-2-4"]="${REMOTE_LIBVIRT_HOSTNAME_2}"

# get cluster libvirt uri or default it the first host
REMOTE_LIBVIRT_URI="qemu+tcp://${LIBVIRT_HOSTS[${LEASED_RESOURCE}]}/system"
if [[ -z "${REMOTE_LIBVIRT_URI}" ]]; then
  REMOTE_LIBVIRT_URI="qemu+tcp://${REMOTE_LIBVIRT_HOSTNAME}/system"
fi
# Debug echo "Remote Libvirt=${REMOTE_LIBVIRT_URI}"
yq write --inplace ${SHARED_DIR}/cluster-config.yaml REMOTE_LIBVIRT_URI ${REMOTE_LIBVIRT_URI}
yq write --inplace ${SHARED_DIR}/cluster-config.yaml CLUSTER_NAME ${LEASED_RESOURCE}-${JOB_NAME_HASH}
yq write --inplace ${SHARED_DIR}/cluster-config.yaml CLUSTER_SUBNET ${CLUSTER_SUBNET}

# Test the remote connection
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list

# Create a list of shared variables among containers
printf "REMOTE_LIBVIRT_URI=%s\n" "${REMOTE_LIBVIRT_URI}" > ${ARTIFACT_DIR}/shared_variables
# TO-DO Remove once Boskos Monitor Controller for MA CI merges
# Assume lease hasn't been cleaned
CONNECT=${REMOTE_LIBVIRT_URI}
# Remove conflicting domains
for DOMAIN in $(mock-nss.sh virsh -c "${CONNECT}" list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${CONNECT}" destroy "${DOMAIN}" || true
  mock-nss.sh virsh -c "${CONNECT}" undefine "${DOMAIN}" || true
done
# Remove conflicting pools
for POOL in $(mock-nss.sh virsh -c "${CONNECT}" pool-list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${CONNECT}" pool-destroy "${POOL}" || true
  mock-nss.sh virsh -c "${CONNECT}" pool-undefine "${POOL}" || true
done
# Remove conflicting networks
for NET in $(mock-nss.sh virsh -c "${CONNECT}" net-list --all --name | grep "${LEASED_RESOURCE}")
do
  mock-nss.sh virsh -c "${CONNECT}" net-destroy "${NET}" || true
  mock-nss.sh virsh -c "${CONNECT}" net-undefine "${NET}" || true
done
# Detect conflicts
CONFLICTING_DOMAINS=$(mock-nss.sh virsh -c "${CONNECT}" list --all --name | grep "${LEASED_RESOURCE}" || true)
CONFLICTING_POOLS=$(mock-nss.sh virsh -c "${CONNECT}" pool-list --all --name | grep "${LEASED_RESOURCE}" || true)
CONFLICTING_NETWORKS=$(mock-nss.sh virsh -c "${CONNECT}" net-list --all --name | grep "${LEASED_RESOURCE}" || true)
if [ ! -z "$CONFLICTING_DOMAINS" ] || [ ! -z "$CONFLICTING_POOLS" ] || [ ! -z "$CONFLICTING_NETWORKS" ]; then
  echo "Could not ensure clean state for lease ${LEASED_RESOURCE}"
  echo "Conflicting domains: $CONFLICTING_DOMAINS"
  echo "Conflicting pools: $CONFLICTING_POOLS"
  echo "Conflicting networks: $CONFLICTING_NETWORKS"
  exit 1
fi

NETWORK_NAME="br$(printf ${LEASED_RESOURCE} | tail -c 3)"
CLUSTER_NAME="${LEASED_RESOURCE}-${JOB_NAME_HASH}"
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
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
      dnsmasqOptions:
      - name: "address"
        value: "/.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}/192.168.${CLUSTER_SUBNET}.1"
      if: ${NETWORK_NAME}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF
