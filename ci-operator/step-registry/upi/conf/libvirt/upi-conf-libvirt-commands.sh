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

LEASE_CONF="${CLUSTER_PROFILE_DIR}/leases"
# shellcheck source=../../libvirt/cluster-context/upi-libvirt-cluster-context-commands.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../libvirt/cluster-context" && pwd)/upi-libvirt-cluster-context-commands.sh"
upi_libvirt_cluster_context_init
leaseLookup() { upi_libvirt_cluster_lease_lookup "$1"; }

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

# Default UPI installation
echo "Create the install-config.yaml file for ${CLUSTER_NAME}..."
cat >> "${CLUSTER_WORK_DIR}/install-config.yaml" << EOF
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

if [ ${FIPS_ENABLED} = "true" ]; then
	echo "Adding 'fips: true' to the install config..."
	cat >> "${CLUSTER_WORK_DIR}/install-config.yaml" << EOF
fips: true
EOF
fi

if [ ! -z "${OS_IMAGE_STREAM}" ]; then
	echo "Adding 'OSImageStream: ${OS_IMAGE_STREAM}' to the install config..."
	cat >> "${CLUSTER_WORK_DIR}/install-config.yaml" << EOF
osImageStream: "${OS_IMAGE_STREAM}"
EOF
fi

if [ -n "${FEATURE_SET}" ]; then
        echo "Adding 'featureSet: ...' to install-config.yaml"
        cat >> "${CLUSTER_WORK_DIR}/install-config.yaml" << EOF
featureSet: ${FEATURE_SET}
EOF
fi

if [ ${NODE_TUNING} = "true" ]; then
  echo "Saving node tuning yaml config..."
  cat >> "${CLUSTER_WORK_DIR}/99-sysctl-worker.yaml" << EOF
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
          # kernel.sched_migration_cost_ns=25000
          source: data:text/plain;charset=utf-8;base64,a2VybmVsLnNjaGVkX21pZ3JhdGlvbl9jb3N0X25zID0gMjUwMDA=
        filesystem: root
        mode: 0644
        overwrite: true
        path: /etc/sysctl.conf
EOF
fi

# Add the chrony config for ppc64le
# setting it to clock.corp.redhat.com
if [ ${ARCH} = "ppc64le" ]; then
  echo "Saving chrony worker yaml config..."
  cat >> "${CLUSTER_WORK_DIR}/99-chrony-worker.yaml" << EOF
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

  echo "Saving chrony master yaml config..."
  cat >> "${CLUSTER_WORK_DIR}/99-chrony-master.yaml" << EOF
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
        mode: 0644
        overwrite: true
        path: /etc/chrony.conf
EOF
fi
