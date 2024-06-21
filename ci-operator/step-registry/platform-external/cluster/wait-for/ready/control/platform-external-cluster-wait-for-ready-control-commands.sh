#!/bin/bash

#
# Platform agnostic check waiting for control plane nodes stayed in Ready phase.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

function wait_for_masters() {
  log "0/ wait_for_masters()"
  set +e
  until oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s; do
    log "Checking masters..."
    oc get nodes -l node-role.kubernetes.io/master
    if [[ "$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l)" -eq 3 ]] ; then
      log "Found 3 masters nodes, exiting..."
      break
    fi
    sleep 30
  done
  log "1/ wait_for_masters() done"
  oc get nodes -l node-role.kubernetes.io/master=''
}

log "=> Waiting for Control Plane nodes"

wait_for_masters &
wait "$!"

oc get nodes
