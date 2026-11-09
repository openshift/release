#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"

if [[ -z "${COVERAGE_IMAGE:-}" ]]; then
    log "ERROR: COVERAGE_IMAGE is required"
    exit 1
fi

log "Setting up e2e coverage for ${OPERATOR_NAME}"
log "  Coverage image: ${COVERAGE_IMAGE}"
log "  Deployment: ${OPERATOR_DEPLOYMENT_NAME}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Scale down PKO to prevent reconciliation reverting our patch
log "Scaling down PKO to prevent reconciliation"
oc scale deployment package-operator-manager -n openshift-package-operator --replicas=0 || true
oc rollout status deployment package-operator-manager -n openshift-package-operator --timeout=60s 2>/dev/null || true

# Patch the operator deployment with coverage image, GOCOVERDIR, and emptyDir volume.
# Use strategic merge patch to handle missing arrays (volumes, volumeMounts).
log "Patching deployment with coverage image"
CONTAINER_NAME=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].name}')
oc patch deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" --type=strategic -p "{
    \"spec\": {
        \"template\": {
            \"spec\": {
                \"containers\": [{
                    \"name\": \"${CONTAINER_NAME}\",
                    \"image\": \"${COVERAGE_IMAGE}\",
                    \"env\": [{\"name\": \"GOCOVERDIR\", \"value\": \"/tmp/e2e-cover\"}],
                    \"volumeMounts\": [{\"name\": \"coverage-data\", \"mountPath\": \"/tmp/e2e-cover\"}]
                }],
                \"volumes\": [{\"name\": \"coverage-data\", \"emptyDir\": {}}]
            }
        }
    }
}"

# Delete old pods to force rollout instead of waiting for graceful termination
log "Deleting old operator pods to force rollout"
SELECTOR=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(f'{k}={v}' for k,v in d.items()))" 2>/dev/null || echo "")
if [[ -n "${SELECTOR}" ]]; then
    oc delete pods -n "${OPERATOR_NAMESPACE}" -l "${SELECTOR}" --force --grace-period=0 2>/dev/null || true
else
    oc delete pods -n "${OPERATOR_NAMESPACE}" --all --force --grace-period=0 2>/dev/null || true
fi

log "Waiting for rollout with coverage image"
oc rollout status deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=180s

log "Coverage setup complete"
