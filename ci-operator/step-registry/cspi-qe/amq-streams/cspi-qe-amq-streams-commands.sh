#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

ADMIN_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")
CLUSTER_API_URL=$(oc whoami --show-server)
OUTPUT_DIR=${ARTIFACT_DIR}

export USER_NAME=kubeadmin
export PASSWORD="${ADMIN_PASSWORD}"
export API_URL="${CLUSTER_API_URL}"
export NAMESPACE=openshift-streams
export KUBECONFIG=${SHARED_DIR}/kubeconfig


/bin/bash -c "make interop && cp -r /tmp/ $OUTPUT_DIR && oc delete -f scenario -n $NAMESPACE"
