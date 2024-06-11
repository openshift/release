#!/bin/bash

#
# Wait for the Kube API is available on bootstrap node.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

UP_COUNT=0
while true; do
  if [[ $UP_COUNT -ge 5 ]];
  then
    break;
  fi
  if oc get infrastructure >/dev/null; then
    UP_COUNT=$(( UP_COUNT + 1 ))
    log "API UP [$UP_COUNT/5]"
    sleep 5
    continue
  fi
  log "API DOWN, waiting 30s..."
  sleep 30
done

log "API Healthy check done!"

log "Dumping infrastructure object"
oc get infrastructure -o yaml
