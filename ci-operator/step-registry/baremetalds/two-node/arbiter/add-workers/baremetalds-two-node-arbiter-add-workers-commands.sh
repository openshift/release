#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

WORKER_COUNT=2
BMH_AVAILABLE_TIMEOUT="30m"
MACHINE_RUNNING_TIMEOUT="45m"
NODE_READY_TIMEOUT="30m"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_step() {
    echo ""
    echo "### $* ###"
}

setup_environment() {
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        log "Loading proxy configuration"
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
}

create_bmh_resources() {
    log_step "Creating BMH CRs from extraworkers secret"
    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        log "Creating extraworker-${i} secret and BMH..."
        oc get secret extraworkers-secret -n openshift-machine-api \
            -o jsonpath="{.data.extraworker-${i}-secret}" | base64 -d | oc apply -f -
        oc get secret extraworkers-secret -n openshift-machine-api \
            -o jsonpath="{.data.extraworker-${i}-bmh}" | base64 -d | oc apply -f -
    done
}

wait_for_bmh_available() {
    log_step "Waiting for BMHs to become available"
    local bmh_names=""
    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        bmh_names+="bmh/ostest-extraworker-${i} "
    done
    # shellcheck disable=SC2086
    oc wait ${bmh_names} \
        -n openshift-machine-api \
        --for=jsonpath='{.status.provisioning.state}'=available \
        --timeout="${BMH_AVAILABLE_TIMEOUT}"
    log "BMHs are available:"
    oc get bmh -n openshift-machine-api
}

scale_worker_machineset() {
    log_step "Scaling worker machineset to ${WORKER_COUNT} replicas"
    MACHINESET=$(oc get machinesets -n openshift-machine-api \
        -o jsonpath='{.items[?(@.spec.template.metadata.labels.machine\.openshift\.io/cluster-api-machine-role=="worker")].metadata.name}')
    if [[ -z "${MACHINESET}" ]]; then
        log "Error: Could not find worker machineset"
        exit 1
    fi
    log "Found worker machineset: ${MACHINESET}"
    oc scale machineset "${MACHINESET}" -n openshift-machine-api --replicas="${WORKER_COUNT}"
}

wait_for_machines_running() {
    log_step "Waiting for machines to be Running"
    oc wait machines -n openshift-machine-api \
        -l "machine.openshift.io/cluster-api-machineset=${MACHINESET}" \
        --for=jsonpath='{.status.phase}'=Running \
        --timeout="${MACHINE_RUNNING_TIMEOUT}"
    log "Machines are running:"
    oc get machines -n openshift-machine-api
}

wait_for_nodes_ready() {
    log_step "Waiting for worker nodes to be Ready"
    oc wait nodes \
        -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' \
        --for=condition=Ready \
        --timeout="${NODE_READY_TIMEOUT}"
    log "Worker nodes are ready:"
    oc get nodes -l 'node-role.kubernetes.io/worker'
}

log_step "Adding ${WORKER_COUNT} extra workers to TNA cluster"

setup_environment
create_bmh_resources
wait_for_bmh_available
scale_worker_machineset
wait_for_machines_running
wait_for_nodes_ready

log_step "Extra workers successfully added to TNA cluster"
