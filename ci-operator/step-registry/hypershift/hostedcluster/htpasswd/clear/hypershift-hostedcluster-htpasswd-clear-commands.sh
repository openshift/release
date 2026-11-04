#!/usr/bin/env bash
set -euo pipefail

echo HyperShift CLI version
/usr/bin/hypershift version

export MGMT_KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
CLUSTER_NAME="$(cat ${SHARED_DIR}/cluster-name)"
export CLUSTER_NAME

echo "Removing htpasswd secret from cluster: ${CLUSTER_NAME}"
oc --kubeconfig=${MGMT_KUBECONFIG} -n clusters delete --ignore-not-found secret htpasswd-${CLUSTER_NAME}
oc --kubeconfig=${MGMT_KUBECONFIG} -n clusters delete --ignore-not-found secret htpasswd-plain-${CLUSTER_NAME}
