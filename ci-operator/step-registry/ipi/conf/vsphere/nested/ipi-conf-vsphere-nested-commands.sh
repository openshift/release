#!/bin/bash

#set -o nounset
#set -o errexit
#set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + "$1"
}

joinByChar() {
  local IFS="$1"
  shift
  echo "$*"
}

SHARED_DIR=/home/rvanderp/code/release-devenv/artifacts/shared

log "provisioning a nested vCenter environment"

declare vcenter_username
declare vcenter_password
source /home/rvanderp/code/release-devenv/vault/vsphere-ibmcloud-ci/nested-secrets.sh

VCPUS=$(jq -r .spec.vcpus < ${SHARED_DIR}/LEASE_single.json)
MEMORY=$(jq -r .spec.memory < ${SHARED_DIR}/LEASE_single.json)

export VCPUS_PER_HOST=$((VCPUS / HOSTS))
export MEMORY_PER_HOST=$(((MEMORY / HOSTS) * 1024))
export GOVC_CLUSTER=$(basename $(jq -r .status.topology.computeCluster < ${SHARED_DIR}/LEASE_single.json))
export GOVC_DATACENTER=$(basename $(jq -r .status.topology.datacenter < ${SHARED_DIR}/LEASE_single.json))
export GOVC_NETWORK=$(basename $(jq -r .status.topology.networks[0] < ${SHARED_DIR}/LEASE_single.json))
export MAINVCHOSTNAME=$(jq -r .status.server < ${SHARED_DIR}/LEASE_single.json)
export MAINVCUSERNAME="${vcenter_username}"
export MAINVCPASSWORD="${vcenter_password}"

log "provisioning to:"
log " vCenter: ${MAINVCHOSTNAME}"
log " datacenter: ${GOVC_DATACENTER}"
log " cluster: ${GOVC_CLUSTER}"
log " network: ${GOVC_NETWORK}"
log "provisioning: "
log " hosts: ${HOSTS}"
log " vCPUs: ${VCPUS}"
log " memory: ${MEMORY}"
log " version: ${VCENTER_VERSION}"

HOST_SLICE=()

for ((i=1; i<=HOSTS; i++)); do
    HOST="${NAMESPACE}-host-${i}"
    HOST_SLICE+=("${HOST}")
    log " host: ${HOST}"
done

TARGET_HOSTS=$(joinByChar , "${HOST_SLICE[@]}")
VCENTER_NAME="$NAMESPACE-vcenter"
log " vCenter: ${VCENTER_NAME}"
log " target_hosts: ${TARGET_HOSTS}"

# ansible-playbook -i hosts main.yml --extra-var version="${VCENTER_VERSION}" --extra-var='{"target_hosts": ['$TARGET_HOSTS']}' --extra-var='{"target_vcs": ['$VCENTER_NAME']}' --extra-var esximemory="${MEMORY_PER_HOST}" --extra-var esxicpu="${VCPUS_PER_HOST}"