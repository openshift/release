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

log "provisioning a nested vCenter environment"

declare vcenter_username
declare vcenter_password
source /var/run/vault/vsphere-ibmcloud-ci/nested-secrets.sh

VCPUS=$(jq -r .spec.vcpus < ${SHARED_DIR}/LEASE_single.json)
MEMORY=$(jq -r .spec.memory < ${SHARED_DIR}/LEASE_single.json)

declare -a vips
mapfile -t vips <"${SHARED_DIR}"/vips.txt

export API_VIP="${vips[0]}"
export INGRESS_VIP="${vips[1]}"

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

NESTED_DATACENTER_ARR=()
NESTED_CLUSTER_ARR=()

for i in $(seq 0 $((NESTED_DATACENTERS - 1))); do 
  NESTED_DATACENTER_ARR+=("cidatacenter-nested-${i}")
  for c in $(seq 0 $((NESTED_CLUSTERS - 1))); do
    c_idx=$((i * 2 + $c)) 
    NESTED_CLUSTER_ARR+=("cicluster-nested-${c}")
  done
done

export NESTED_DATACENTER=${NESTED_DATACENTER_ARR[0]}
export NESTED_CLUSTER=${NESTED_CLUSTER_ARR[0]}

log "building additional variables"
cat "${SHARED_DIR}/nested-ansible-group-vars.yaml" | envsubst >> /tmp/additional-vars.yml

log "starting provisioning playbook"
ansible-playbook -i hosts main.yml --extra-var "@/tmp/additional-vars.yml" --extra-var version="${VCENTER_VERSION}" --extra-var='{"target_hosts": ['$TARGET_HOSTS']}' --extra-var='{"target_vcs": ['$VCENTER_NAME']}' --extra-var esximemory="${MEMORY_PER_HOST}" --extra-var esxicpu="${VCPUS_PER_HOST}"

export NESTED_VCENTER_IP="$(cat /tmp/vcenterip)"
export NESTED_VCENTER="$(dig -x "${NESTED_VCENTER_IP}" +short)"
export NESTED_VCENTER="${NESTED_VCENTER::-1}"

log "updating installation artifacts to use the nested vCenter ${NESTED_VCENTER}"

# to-do: get CA cert(we may need to patch the cluster-profile or vault certificate)

if [ -f "${SHARED_DIR}/nested-ansible-platform.yaml" ]; then
  log "replacing the platform spec with the nested platform spec"
  yq 'del(.platform)' < "${SHARED_DIR}/install-config.yaml" > /tmp/install-config.yaml
  cat "${SHARED_DIR}/nested-ansible-platform.yaml" | envsubst >> /tmp/install-config.yaml
  cp /tmp/install-config.yaml "${SHARED_DIR}/install-config.yaml"

  log "updating platform.json and platform.yaml"
  yq -o=json .platform.vsphere < /tmp/install-config.yaml > "${SHARED_DIR}/platform.json"
  yq -P . < "${SHARED_DIR}/_platform.json" | sed -e 's/^/    /' | envsubst > "${SHARED_DIR}/platform.yaml"
fi

log "extracting CA cert"
curl -k -O "https://${NESTED_VCENTER}/certs/download.zip"
unzip download.zip
cat certs/lin/*.0 > "${SHARED_DIR}/additional_ca_cert.pem"
