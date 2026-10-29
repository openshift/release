#!/bin/bash

#
# Setup Image Registry storage to EmptyDir.
# Depends on: control plane ready
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

function update_image_registry() {
  log "update_image_registry()"
  while true; do
    sleep 30;
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
  done
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
  log "update_image_registry() done"
}

update_image_registry
