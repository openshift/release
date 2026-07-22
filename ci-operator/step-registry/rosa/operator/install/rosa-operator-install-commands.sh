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
CLUSTER_PACKAGE_NAME="${CLUSTER_PACKAGE_NAME:-${OPERATOR_NAME}-e2e-test}"

log "Installing ${OPERATOR_NAME} via PKO ClusterPackage"
log "  ClusterPackage: ${CLUSTER_PACKAGE_NAME}"
log "  PKO image: ${OPERATOR_PKO_IMAGE}"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Mirror CI-built images to the cluster's internal registry so PKO can pull
# them without modifying the global pull secret. This avoids a race condition
# when multiple operators share a lease cluster concurrently: each job's CI
# registry token is scoped to its own ci-op namespace, and docker config auth
# is keyed by registry host, so the last writer's token wins.
MIRROR_NS="ci-e2e-images"
REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [[ -z "${REGISTRY_ROUTE}" ]]; then
    log "WARNING: Internal registry route not found, falling back to direct pull"
else
    log "Mirroring CI images to internal registry"
    log "  Registry: ${REGISTRY_ROUTE}"

    MIRROR_TMPDIR=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf ${MIRROR_TMPDIR}" EXIT

    oc create namespace "${MIRROR_NS}" 2>/dev/null || true
    oc create sa image-pusher -n "${MIRROR_NS}" 2>/dev/null || true
    oc adm policy add-role-to-user registry-editor -z image-pusher -n "${MIRROR_NS}" 2>/dev/null || true

    if ! SA_TOKEN=$(oc create token image-pusher -n "${MIRROR_NS}" --duration=10m 2>/dev/null); then
        log "WARNING: Failed to create SA token, falling back to direct pull"
    elif ! KUBECONFIG="" oc registry login --to="${MIRROR_TMPDIR}/ci-creds.json" 2>/dev/null; then
        log "WARNING: Failed to get CI registry creds, falling back to direct pull"
    else
        AUTH_B64=$(echo -n "image-pusher:${SA_TOKEN}" | base64 -w0 2>/dev/null || echo -n "image-pusher:${SA_TOKEN}" | base64)
        echo "{\"auths\":{\"${REGISTRY_ROUTE}\":{\"auth\":\"${AUTH_B64}\"}}}" > "${MIRROR_TMPDIR}/dest-creds.json"
        if ! jq -s '.[0] * .[1]' "${MIRROR_TMPDIR}/ci-creds.json" "${MIRROR_TMPDIR}/dest-creds.json" > "${MIRROR_TMPDIR}/auth.json" 2>/dev/null; then
            log "WARNING: Failed to merge registry creds, falling back to direct pull"
        else
            BUILD_TAG="${BUILD_ID:-$(date +%s)}"
            MIRRORED_PKO_IMAGE="${REGISTRY_ROUTE}/${MIRROR_NS}/${OPERATOR_NAME}-pko:${BUILD_TAG}"
            MIRRORED_OPERATOR_IMAGE="${REGISTRY_ROUTE}/${MIRROR_NS}/${OPERATOR_NAME}:${BUILD_TAG}"

            log "  PKO: ${OPERATOR_PKO_IMAGE} -> ${MIRRORED_PKO_IMAGE}"
            if oc image mirror --registry-config="${MIRROR_TMPDIR}/auth.json" \
                "${OPERATOR_PKO_IMAGE}" "${MIRRORED_PKO_IMAGE}" --insecure=true 2>&1; then
                OPERATOR_PKO_IMAGE="${MIRRORED_PKO_IMAGE}"
                log "  PKO image mirrored"
            else
                log "WARNING: Failed to mirror PKO image, falling back to direct pull"
            fi

            log "  Operator: ${OPERATOR_IMAGE} -> ${MIRRORED_OPERATOR_IMAGE}"
            if oc image mirror --registry-config="${MIRROR_TMPDIR}/auth.json" \
                "${OPERATOR_IMAGE}" "${MIRRORED_OPERATOR_IMAGE}" --insecure=true 2>&1; then
                OPERATOR_IMAGE="${MIRRORED_OPERATOR_IMAGE}"
                log "  Operator image mirrored"
            else
                log "WARNING: Failed to mirror operator image, falling back to direct pull"
            fi
        fi
    fi
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
    # Wait for the resource to be fully gone before recreating with the same name.
    # PKO finalizers can delay actual deletion beyond what --timeout reports.
    # Use --ignore-not-found so a 404 returns empty output (exit 0) while
    # transient API errors still produce a non-empty error and non-zero exit.
    for i in $(seq 1 24); do
        RESULT=$(oc get clusterpackage "${OPERATOR_NAME}" --ignore-not-found -o name 2>&1) || true
        if [[ -z "${RESULT}" ]]; then
            break
        fi
        if [[ $i -eq 24 ]]; then
            log "WARNING: ClusterPackage ${OPERATOR_NAME} still exists after 2 minutes, forcing removal"
            oc patch clusterpackage "${OPERATOR_NAME}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        fi
        sleep 5
    done
    # Confirm deletion after force-removal
    RESULT=$(oc get clusterpackage "${OPERATOR_NAME}" --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "ERROR: ClusterPackage ${OPERATOR_NAME} could not be removed: ${RESULT}"
        exit 1
    fi
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

# Also remove any leftover e2e ClusterPackage from a previous run
if [[ "${CLUSTER_PACKAGE_NAME}" != "${OPERATOR_NAME}" ]]; then
    RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "Removing leftover e2e ClusterPackage ${CLUSTER_PACKAGE_NAME}"
        oc delete clusterpackage "${CLUSTER_PACKAGE_NAME}" --timeout=60s || true
        for i in $(seq 1 12); do
            RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
            if [[ -z "${RESULT}" ]]; then
                break
            fi
            if [[ $i -eq 12 ]]; then
                log "WARNING: ClusterPackage ${CLUSTER_PACKAGE_NAME} still exists, forcing removal"
                oc patch clusterpackage "${CLUSTER_PACKAGE_NAME}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            fi
            sleep 5
        done
        RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
        if [[ -n "${RESULT}" ]]; then
            log "ERROR: ClusterPackage ${CLUSTER_PACKAGE_NAME} could not be removed: ${RESULT}"
            exit 1
        fi
    fi
fi

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
