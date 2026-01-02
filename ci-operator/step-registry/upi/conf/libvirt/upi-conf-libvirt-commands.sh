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

function leaseLookup () {
  local lookup
  lookup=$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".${1}" "${CLUSTER_PROFILE_DIR}/leases")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${1} in lease config"
    exit 1
  fi
  echo "$lookup"
}

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

BASE_DOMAIN="${LEASED_RESOURCE}.ci"
CLUSTER_NAME="${LEASED_RESOURCE}-${UNIQUE_HASH}"

# Default UPI installation
echo "Create the install-config.yaml file..."
cat >> "${SHARED_DIR}/install-config.yaml" << EOF
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
	cat >> "${SHARED_DIR}/install-config.yaml" << EOF
fips: true
EOF
fi

if [ ${NODE_TUNING} = "true" ]; then
  echo "Saving node tuning yaml config..."
  cat >> ${SHARED_DIR}/99-sysctl-worker.yaml << EOF
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
  cat >> ${SHARED_DIR}/99-chrony-worker.yaml << EOF
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
  cat >> ${SHARED_DIR}/99-chrony-master.yaml << EOF
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
