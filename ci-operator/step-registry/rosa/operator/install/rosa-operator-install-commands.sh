#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Use shared kubeconfig from provision step if available
if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

if [[ -z "${OPERATOR_PKO_IMAGE:-}" ]]; then
    log "ERROR: OPERATOR_PKO_IMAGE is required"
    exit 1
fi

if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
    log "ERROR: OPERATOR_IMAGE is required"
    exit 1
fi

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"

log "Installing ${OPERATOR_NAME} via PKO ClusterPackage"
log "  PKO image: ${OPERATOR_PKO_IMAGE}"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Create namespace if it doesn't exist
oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Apply CRDs from the repo source if available
if [[ -d "${OPERATOR_CRD_DIR:-}" ]]; then
    log "Applying CRDs from ${OPERATOR_CRD_DIR}"
    oc apply -f "${OPERATOR_CRD_DIR}"
fi

# Create the ClusterPackage CR
cat <<EOF | oc apply -f -
apiVersion: package-operator.run/v1alpha1
kind: ClusterPackage
metadata:
  name: ${OPERATOR_NAME}
  annotations:
    package-operator.run/collision-protection: IfNoController
spec:
  image: ${OPERATOR_PKO_IMAGE}
  config:
    image: ${OPERATOR_IMAGE}
EOF

# Wait for the operator deployment to be available
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to be ready..."
oc wait deployment "${OPERATOR_DEPLOYMENT_NAME}" \
    -n "${OPERATOR_NAMESPACE}" \
    --for=condition=Available \
    --timeout=300s

log "${OPERATOR_NAME} installed and ready"
