#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true
install_jq

function wait_for_workers() {
  # TODO improve this check
  all_approved_offset=0
  all_approved_limit=10
  all_approved_check_delay=10
  log "wait_for_workers()"
  while true; do
    test $all_approved_offset -ge $all_approved_limit && break
    log "Checking workers..."
    log "Waiting for workers approved..."
    oc get nodes -l node-role.kubernetes.io/worker
    if [[ "$(oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | wc -l)" -ge 1 ]]; then
      log "Detected pending certificates, approving..."
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      all_approved_offset=$(( all_approved_offset + 1 ))
      sleep $all_approved_check_delay
      continue
    fi
    if [[ "$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers 2>/dev/null | wc -l)" -eq 3 ]] ; then
      log "Found 3 worker nodes, existing..."
      break
    fi
    log "Waiting for certificates..."
    sleep 15
  done
  log "Starting workers ready waiter..."
  until oc wait node --selector='node-role.kubernetes.io/worker' --for condition=Ready --timeout=30s; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    log "Waiting for workers join..."
    sleep 10
  done
  log "wait_for_workers() done"
  oc get nodes -l node-role.kubernetes.io/master=''
}

log "=> Waiting for Compute nodes"

wait_for_workers &
wait "$!"

oc get nodes