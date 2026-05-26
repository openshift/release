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
CLUSTER_PACKAGE_NAME="${OPERATOR_NAME}-e2e-test"

log "Installing ${OPERATOR_NAME} via PKO ClusterPackage"
log "  ClusterPackage: ${CLUSTER_PACKAGE_NAME}"
log "  PKO image: ${OPERATOR_PKO_IMAGE}"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Add CI build cluster registry credentials to the ROSA cluster's global
# pull secret so nodes can pull CI-built images. We temporarily unset
# KUBECONFIG so oc registry login authenticates to the build cluster
# (where the Prow pod runs), not the ROSA cluster.
log "Adding CI registry credentials to cluster pull secret"
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-creds.json 2>/dev/null || true
if [[ -s /tmp/ci-registry-creds.json ]]; then
    CI_REGISTRIES=$(jq -r '.auths | keys | join(", ")' /tmp/ci-registry-creds.json 2>/dev/null || echo "unknown")
    log "CI registries: ${CI_REGISTRIES}"

    # Update the global pull secret
    CURRENT_PS=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
    MERGED_PS=$(echo "${CURRENT_PS}" | jq -s '.[0] * .[1]' - /tmp/ci-registry-creds.json)
    echo "${MERGED_PS}" > /tmp/merged-pull-secret.json
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json
    log "CI registry credentials merged into global pull secret"

    # Also create an image pull secret in the package-operator namespace
    # so PKO can pull immediately without waiting for MCO to propagate
    oc create secret docker-registry ci-pull-secret \
        -n openshift-package-operator \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    # Patch the PKO service account to use the pull secret
    oc patch sa package-operator -n openshift-package-operator \
        --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
    log "CI pull secret added to PKO namespace"

    # Restart PKO to pick up the new pull secret
    oc rollout restart deployment -n openshift-package-operator 2>/dev/null || true
    oc rollout status deployment -n openshift-package-operator --timeout=120s 2>/dev/null || true
    log "PKO restarted with CI pull secret"
else
    log "WARNING: Could not get CI registry credentials, PKO may fail to pull images"
fi

# Save operator CR instances before removing the ClusterPackage.
# On managed clusters, SSS deploys CRs (RouteMonitors, etc.) that we need
# to preserve. Deleting the ClusterPackage may cascade-delete CRDs and CRs.
# We back up all CR instances for each operator CRD, then restore after install.
CR_BACKUP_DIR="/tmp/operator-cr-backup"
mkdir -p "${CR_BACKUP_DIR}"
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if oc get crd "${crd}" &>/dev/null; then
            RESOURCE=$(oc get crd "${crd}" -o jsonpath='{.spec.names.plural}')
            GROUP=$(oc get crd "${crd}" -o jsonpath='{.spec.group}')
            log "Backing up ${RESOURCE}.${GROUP} instances"
            oc get "${RESOURCE}.${GROUP}" -A -o yaml > "${CR_BACKUP_DIR}/${crd}.yaml" 2>/dev/null || true
        fi
    done
fi

# Remove existing operator resources that conflict with PKO adoption.
# On managed clusters, operators are pre-deployed via SSS/PKO. PKO refuses
# to adopt CRDs owned by a different ClusterObjectSet. We remove:
# 1. The existing ClusterPackage (releases the ClusterObjectSet)
# 2. Orphaned ClusterObjectSets (releases CRD ownerReferences)
# 3. CRD ownerReferences (so PKO can adopt them fresh)
# Safe on ephemeral clusters only.
if oc get clusterpackage "${OPERATOR_NAME}" &>/dev/null; then
    log "Removing existing ClusterPackage ${OPERATOR_NAME}"
    oc delete clusterpackage "${OPERATOR_NAME}" --timeout=120s || true
    sleep 5
fi

# Remove orphaned ClusterObjectSets from the old package
for cos in $(oc get clusterobjectset -o name 2>/dev/null | grep "${OPERATOR_NAME}" | grep -v "${CLUSTER_PACKAGE_NAME}" || true); do
    log "Removing orphaned ${cos}"
    # Remove finalizers first to avoid hanging deletes
    oc patch "${cos}" --type merge -p '{"metadata":{"finalizers":[]}}' || true
    oc delete "${cos}" --timeout=60s || true
done

# Clear ownerReferences on operator CRDs so PKO can adopt them
if [[ -n "${OPERATOR_CRDS:-}" ]]; then
    IFS=',' read -ra CRD_LIST <<< "${OPERATOR_CRDS}"
    for crd in "${CRD_LIST[@]}"; do
        crd=$(echo "${crd}" | xargs)
        if oc get crd "${crd}" &>/dev/null; then
            log "Clearing ownership on CRD ${crd}"
            oc patch crd "${crd}" --type merge -p '{"metadata":{"ownerReferences":[],"labels":{"package-operator.run/instance":"'"${CLUSTER_PACKAGE_NAME}"'"}}}' || true
        fi
    done
fi
sleep 5

# Create the ClusterPackage CR
cat <<EOF | oc apply -f -
apiVersion: package-operator.run/v1alpha1
kind: ClusterPackage
metadata:
  name: ${CLUSTER_PACKAGE_NAME}
  annotations:
    package-operator.run/collision-protection: None
spec:
  image: ${OPERATOR_PKO_IMAGE}
  config:
    image: ${OPERATOR_IMAGE}
EOF

# Save the ClusterPackage name for cleanup
if [[ -n "${SHARED_DIR:-}" ]]; then
    echo "${CLUSTER_PACKAGE_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
    echo "${OPERATOR_NAMESPACE}" > "${SHARED_DIR}/operator-e2e-namespace"
fi

# Wait for PKO to reconcile and create the deployment
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to exist..."
for i in $(seq 1 30); do
    if oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} not found after 5 minutes"
        oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" -o yaml || true
        oc get clusterobjectset -o wide 2>/dev/null | grep "${OPERATOR_NAME}" || true
        exit 1
    fi
    sleep 10
done

# Wait for the operator deployment to be available
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to be ready..."
oc wait deployment "${OPERATOR_DEPLOYMENT_NAME}" \
    -n "${OPERATOR_NAMESPACE}" \
    --for=condition=Available \
    --timeout=300s

log "${OPERATOR_NAME} installed and ready in ${OPERATOR_NAMESPACE}"

# Restore backed-up CR instances that were deployed by SSS/MCC
for backup in "${CR_BACKUP_DIR}"/*.yaml; do
    [[ -f "${backup}" ]] || continue
    if [[ -s "${backup}" ]]; then
        crd_name=$(basename "${backup}" .yaml)
        log "Restoring CR instances for ${crd_name}"
        oc apply -f "${backup}" 2>/dev/null || true
    fi
done
