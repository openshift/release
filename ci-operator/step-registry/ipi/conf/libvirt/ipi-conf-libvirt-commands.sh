#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function write_shared_dir() {
  local key="$1"
  local value="$2"
  yq write --inplace ${SHARED_DIR}/cluster-config.yaml $key $value
}

# TO-DO Remove once Boskos Monitor Controller for MA CI merges
# Assume lease hasn't been cleaned
function cleanup_leftover_resources() {
  local CONNECT=${REMOTE_LIBVIRT_URI}

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
    mock-nss.sh virsh -c "${CONNECT}" pool-delete "${POOL}" || true
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
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# ensure RELEASE_IMAGE_LATEST is set
if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

# create a file for storing shared information between steps
touch ${SHARED_DIR}/cluster-config.yaml

echo "Installing from initial release ${RELEASE_IMAGE_LATEST}"

openshift-install version

CONFIG="${SHARED_DIR}/install-config.yaml"
# TO_DO Remove CLUSTER SUBNET 126 after HA-Proxy changes on host
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

# get cluster subnet or default it to 126
# TO-DO default to 1 after HA-Proxy changes on host
CLUSTER_SUBNET="${SUBNETS[${LEASED_RESOURCE}]}"
if [[ -z "${CLUSTER_SUBNET}" ]]; then
  CLUSTER_SUBNET=126
fi

# Setting Hostnames
if [[ "${ARCH}" == "s390x" ]]; then
  REMOTE_LIBVIRT_HOSTNAME=lnxocp01
  REMOTE_LIBVIRT_HOSTNAME_1=lnxocp02
  REMOTE_LIBVIRT_HOSTNAME_2=lnxocp06
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
write_shared_dir REMOTE_LIBVIRT_URI ${REMOTE_LIBVIRT_URI}

CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"
write_shared_dir CLUSTER_NAME ${CLUSTER_NAME}

# Test the remote connection
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list

# in case the cluster deprovision failed in a previous run
cleanup_leftover_resources

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
cat >> "${CONFIG}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
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
  networkType: OVNKubernetes
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
        value: "/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/192.168.${CLUSTER_SUBNET}.1"
      if: "br$(printf ${LEASED_RESOURCE} | tail -c 3)"
pullSecret: >
  $(<"${CLUSTER_PROFILE_DIR}/pull-secret")
sshKey: |
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	cat >> "${CONFIG}" << EOF
fips: true
EOF
fi

# DNS records for libvirt versions that don't support dnsmasq options
cat >> ${SHARED_DIR}/worker-hostrecords.xml << EOF
<host ip='192.168.${CLUSTER_SUBNET}.1'>
  <hostname>alertmanager-main-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>canary-openshift-ingress-canary.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>downloads-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>grafana-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
  <hostname>test-disruption-openshift-image-registry.apps.${CLUSTER_NAME}.${BASE_DOMAIN}</hostname>
</host>
EOF
