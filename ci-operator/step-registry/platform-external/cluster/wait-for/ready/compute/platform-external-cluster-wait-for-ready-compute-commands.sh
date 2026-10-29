#!/bin/bash

#
# Platform agnostic step to Wait for compute nodes are in ready phase.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true
install_jq

function wait_for_workers() {
  all_approved_offset=0
  all_approved_limit=10
  all_approved_check_delay=10

  log "wait_for_workers() init"
  log "=> Starting CSR approvers for compute nodes..."
  while true; do
    test $all_approved_offset -ge $all_approved_limit && break

    log "1/ Getting current workers: "
    oc get nodes -l node-role.kubernetes.io/worker || true

    log "2/ Waiting for workers approved..."
    if [[ "$(oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | wc -l)" -ge 1 ]]; then
      log "2A/ Detected pending certificates, approving..."
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true

      log "2B/ Waiting for next csr approval"
      all_approved_offset=$(( all_approved_offset + 1 ))
      sleep $all_approved_check_delay
      continue
    fi

    log "3/ Checking total worker nodes..."
    if [[ "$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers 2>/dev/null | wc -l)" -eq 3 ]] ; then
      log "3A/ Found 3 worker nodes, exiting CSR approver..."
      break
    fi

    log "4/ Waiting 15s to the next check"
    sleep 60
  done

  log "=> Waiting for compute nodes be in Ready status..."
  until oc wait node --selector='node-role.kubernetes.io/worker' --for condition=Ready --timeout=30s; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    log "Waiting for compute nodes to join..."
    sleep 10
  done

  log "wait_for_workers() done"
}

wait_for_workers &
wait "$!"

oc get nodes || true
