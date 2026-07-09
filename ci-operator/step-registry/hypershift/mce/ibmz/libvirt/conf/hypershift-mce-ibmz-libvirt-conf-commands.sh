#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/hypershift-mce-ibmz-libvirt-common.sh
source "${SCRIPT_DIR}/../common/hypershift-mce-ibmz-libvirt-common.sh"

if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "Couldn't find pull secret file"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  echo "Couldn't find ssh public-key file"
  exit 1
fi

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
cluster_libvirt_init
leaseLookup() { cluster_libvirt_lease_lookup "$1"; }

echo "Create install-config.yaml for ${CLUSTER_ROLE} cluster (${CLUSTER_NAME})..."
cat >> "${CLUSTER_DIR}/install-config.yaml" << EOF
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
  - cidr: 10.8.0.0/14
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

if [[ "${FIPS_ENABLED}" == "true" ]]; then
  cat >> "${CLUSTER_DIR}/install-config.yaml" << EOF
fips: true
EOF
fi

if [[ -n "${OS_IMAGE_STREAM}" ]]; then
  cat >> "${CLUSTER_DIR}/install-config.yaml" << EOF
osImageStream: "${OS_IMAGE_STREAM}"
EOF
fi

if [[ -n "${FEATURE_SET}" ]]; then
  cat >> "${CLUSTER_DIR}/install-config.yaml" << EOF
featureSet: ${FEATURE_SET}
EOF
fi

if [[ "${NODE_TUNING}" == "true" ]]; then
  cat >> "${CLUSTER_DIR}/99-sysctl-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-sysctl-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,a2VybmVsLnNjaGVkX21pZ3JhdGlvbl9jb3N0X25zID0gMjUwMDA=
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/sysctl.conf
EOF
fi

if [[ "${ARCH}" == "ppc64le" ]]; then
  cat >> "${CLUSTER_DIR}/99-chrony-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-chrony-worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,c2VydmVyIGNsb2NrLmNvcnAucmVkaGF0LmNvbSBpYnVyc3QKZHJpZnRmaWxlIC92YXIvbGliL2Nocm9ueS9kcmlmdAptYWtlc3RlcCAxLjAgMwpydGNzeW5jCmxvZ2RpciAvdmFyL2xvZy9jaHJvbnkK
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/chrony.conf
EOF

  cat >> "${CLUSTER_DIR}/99-chrony-master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-chrony-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,c2VydmVyIGNsb2NrLmNvcnAucmVkaGF0LmNvbSBpYnVyc3QKZHJpZnRmaWxlIC92YXIvbGliL2Nocm9ueS9kcmlmdAptYWtlc3RlcCAxLjAgMwpydGNzeW5jCmxvZ2RpciAvdmFyL2xvZy9jaHJvbnkK
        filesystem: root
        mode: 420
        overwrite: true
        path: /etc/chrony.conf
EOF
fi
