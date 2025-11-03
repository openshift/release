#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Adding a condition in case the workflow used is servicemesh-mapt when KUBECONFIG is stored in SHARED_DIR/mapt-connection/kubeconfig
if [[ -f "${SHARED_DIR}/mapt-connection/kubeconfig" ]]; then
  KUBECONFIG="${SHARED_DIR}/mapt-connection/kubeconfig"
  export KUBECONFIG
fi

oc delete project "${MAISTRA_NAMESPACE}"
echo "Deleted \"$MAISTRA_NAMESPACE\" Namespace"
