#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

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

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-validation-webhook}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-validation-webhook}"
CLUSTER_PACKAGE_NAME="${CLUSTER_PACKAGE_NAME:-${OPERATOR_NAME}-e2e-test}"

log "Setting up ${OPERATOR_NAME} for e2e testing"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  PKO image:      ${OPERATOR_PKO_IMAGE}"
log "  Namespace:      ${OPERATOR_NAMESPACE}"

# Always merge CI registry credentials into the global pull secret so all
# pods on all nodes can pull CI-built images.
log "Adding CI registry credentials to cluster pull secret"
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-creds.json 2>/dev/null || true
if [[ -s /tmp/ci-registry-creds.json ]]; then
    for attempt in $(seq 1 5); do
        SECRET_JSON=$(oc get secret pull-secret -n openshift-config -o json)
        CURRENT_PS=$(echo "${SECRET_JSON}" | jq -r '.data[".dockerconfigjson"]' | base64 -d)
        MERGED_PS=$(echo "${CURRENT_PS}" | jq -s '.[0] * .[1]' - /tmp/ci-registry-creds.json)
        MERGED_B64=$(echo "${MERGED_PS}" | base64 -w0 2>/dev/null || echo "${MERGED_PS}" | base64)
        UPDATED=$(echo "${SECRET_JSON}" | jq '.data[".dockerconfigjson"] = "'"${MERGED_B64}"'"')
        if echo "${UPDATED}" | oc replace -f - 2>/dev/null; then
            log "CI registry credentials merged into global pull secret"
            break
        fi
        if [[ ${attempt} -eq 5 ]]; then
            log "ERROR: Failed to update global pull secret after 5 retries"
            exit 1
        fi
        log "  Pull secret conflict (attempt ${attempt}), retrying..."
        sleep 1
    done
    echo "${MERGED_PS}" > /tmp/merged-pull-secret.json

    oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
    oc create secret docker-registry ci-pull-secret \
        -n "${OPERATOR_NAMESPACE}" \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    log "CI pull secret ready in ${OPERATOR_NAMESPACE}"
else
    log "WARNING: Could not get CI registry credentials"
    oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
fi

if [[ -n "${SHARED_DIR:-}" ]]; then
    echo "${OPERATOR_NAMESPACE}" > "${SHARED_DIR}/operator-e2e-namespace"
fi

# ---- Strategy selection ----
#
# ROSA lease clusters have MCVW deployed via SelectorSyncSet -> PKO ClusterPackage.
# The SSS creates a ClusterPackage CR; PKO reconciles it to create the Deployment,
# Service, ConfigMap etc. Creating a new namespaced Package alongside fails because
# PKO refuses to adopt objects already owned by the ClusterObjectSet (webhook-cert
# ConfigMap etc.) -- even with collision-protection: None, since the ownership
# is held by a different ObjectSet type/revision.
#
# Strategy priority:
#   1. Existing ClusterPackage managing this namespace -> patch it
#   2. Existing namespaced Package -> patch it
#   3. Existing Deployment (non-PKO) -> patch image directly
#   4. Nothing -> create new namespaced Package (fresh cluster)

SERVICE_CA=""
fetch_service_ca() {
    SERVICE_CA=$(oc get configmap openshift-service-ca.crt -n openshift-config \
        -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | base64 -w0 2>/dev/null || \
        oc get configmap openshift-service-ca.crt -n openshift-config \
        -o jsonpath='{.data.service-ca\.crt}' | base64)
    if [[ -z "${SERVICE_CA}" ]]; then
        log "ERROR: Could not fetch service CA"
        exit 1
    fi
    log "Service CA fetched (${#SERVICE_CA} bytes base64)"
}

# Look for a ClusterPackage that manages the validation-webhook namespace.
# SSS-deployed MCVW creates a ClusterPackage with the operator name.
EXISTING_CLUSTERPACKAGE=$(oc get clusterpackage \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | grep -i "managed-cluster-validating\|mcvw\|validation-webhook" | head -1 || true)

EXISTING_PACKAGE=$(oc get package -n "${OPERATOR_NAMESPACE}" \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)

EXISTING_DEPLOYMENT=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" \
    -n "${OPERATOR_NAMESPACE}" --ignore-not-found -o name 2>/dev/null || true)

EXISTING_DAEMONSET=$(oc get daemonset "${OPERATOR_DEPLOYMENT_NAME}" \
    -n "${OPERATOR_NAMESPACE}" --ignore-not-found -o name 2>/dev/null || true)

if [[ -n "${EXISTING_CLUSTERPACKAGE}" ]]; then
    # ---- Mode 1: Patch existing ClusterPackage (SSS -> PKO chain) ----
    log "Found existing ClusterPackage '${EXISTING_CLUSTERPACKAGE}', patching to CI images"
    fetch_service_ca

    ORIG_PKO_IMAGE=$(oc get clusterpackage "${EXISTING_CLUSTERPACKAGE}" \
        -o jsonpath='{.spec.image}')
    ORIG_OP_IMAGE=$(oc get clusterpackage "${EXISTING_CLUSTERPACKAGE}" \
        -o jsonpath='{.spec.config.image}')

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "clusterpackage-patch"    > "${SHARED_DIR}/operator-e2e-mode"
        echo "${EXISTING_CLUSTERPACKAGE}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${ORIG_PKO_IMAGE}"       > "${SHARED_DIR}/operator-e2e-orig-pko-image"
        echo "${ORIG_OP_IMAGE}"        > "${SHARED_DIR}/operator-e2e-orig-op-image"
    fi

    oc patch clusterpackage "${EXISTING_CLUSTERPACKAGE}" \
        --type merge -p \
        "{\"spec\":{\"image\":\"${OPERATOR_PKO_IMAGE}\",\"config\":{\"image\":\"${OPERATOR_IMAGE}\",\"serviceca\":\"${SERVICE_CA}\"}}}"
    log "ClusterPackage '${EXISTING_CLUSTERPACKAGE}' patched to CI images"

elif [[ -n "${EXISTING_PACKAGE}" ]]; then
    # ---- Mode 2: Patch existing namespaced Package ----
    log "Found existing Package '${EXISTING_PACKAGE}', patching to CI images"
    fetch_service_ca

    ORIG_PKO_IMAGE=$(oc get package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.image}')
    ORIG_OP_IMAGE=$(oc get package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.config.image}')

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "package-patch"       > "${SHARED_DIR}/operator-e2e-mode"
        echo "${EXISTING_PACKAGE}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${ORIG_PKO_IMAGE}"   > "${SHARED_DIR}/operator-e2e-orig-pko-image"
        echo "${ORIG_OP_IMAGE}"    > "${SHARED_DIR}/operator-e2e-orig-op-image"
    fi

    oc patch package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        --type merge -p \
        "{\"spec\":{\"image\":\"${OPERATOR_PKO_IMAGE}\",\"config\":{\"image\":\"${OPERATOR_IMAGE}\",\"serviceca\":\"${SERVICE_CA}\"}}}"
    CLUSTER_PACKAGE_NAME="${EXISTING_PACKAGE}"
    log "Package '${EXISTING_PACKAGE}' patched to CI images"

elif [[ -n "${EXISTING_DEPLOYMENT}" ]]; then
    # ---- Mode 3: Direct Deployment image patch (non-PKO managed) ----
    log "Found existing Deployment with no PKO package, patching image directly"

    CONTAINER_NAME=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" \
        -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].name}')
    ORIG_IMAGE=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" \
        -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "deployment-direct"        > "${SHARED_DIR}/operator-e2e-mode"
        echo "${OPERATOR_DEPLOYMENT_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${CONTAINER_NAME}"        > "${SHARED_DIR}/operator-e2e-container-name"
        echo "${ORIG_IMAGE}"            > "${SHARED_DIR}/operator-e2e-orig-op-image"
    fi

    oc set image "deployment/${OPERATOR_DEPLOYMENT_NAME}" \
        "${CONTAINER_NAME}=${OPERATOR_IMAGE}" \
        -n "${OPERATOR_NAMESPACE}"
    log "Deployment image updated to CI build"

elif [[ -n "${EXISTING_DAEMONSET}" ]]; then
    # ---- Mode 3b: Direct DaemonSet image patch (classic ROSA STS via SSS, no PKO) ----
    log "Found existing DaemonSet with no PKO package, patching image directly"

    CONTAINER_NAME=$(oc get daemonset "${OPERATOR_DEPLOYMENT_NAME}" \
        -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].name}')
    ORIG_IMAGE=$(oc get daemonset "${OPERATOR_DEPLOYMENT_NAME}" \
        -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "daemonset-direct"         > "${SHARED_DIR}/operator-e2e-mode"
        echo "${OPERATOR_DEPLOYMENT_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${CONTAINER_NAME}"        > "${SHARED_DIR}/operator-e2e-container-name"
        echo "${ORIG_IMAGE}"            > "${SHARED_DIR}/operator-e2e-orig-op-image"
    fi

    oc set image "daemonset/${OPERATOR_DEPLOYMENT_NAME}" \
        "${CONTAINER_NAME}=${OPERATOR_IMAGE}" \
        -n "${OPERATOR_NAMESPACE}"
    log "DaemonSet image updated to CI build"

else
    # ---- Mode 4: Create new namespaced Package (fresh cluster) ----
    log "No existing ClusterPackage, Package, or Deployment found -- creating new Package"
    fetch_service_ca

    oc create secret docker-registry ci-pull-secret \
        -n openshift-package-operator \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true
    oc patch sa package-operator -n openshift-package-operator \
        --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
    oc rollout restart deployment -n openshift-package-operator 2>/dev/null || true
    oc rollout status deployment -n openshift-package-operator --timeout=120s 2>/dev/null || true
    log "PKO restarted with CI pull secret"

    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "package-create"          > "${SHARED_DIR}/operator-e2e-mode"
        echo "${CLUSTER_PACKAGE_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
    fi

    # SSS creates webhook-cert ConfigMap and validation-webhook Service without
    # PKO owner refs. PKO refuses to adopt them even with collision-protection: None.
    # Save them for restoration in cleanup, then delete so PKO can create them fresh.
    log "Saving SSS-managed resources for post-test restoration"
    if [[ -n "${SHARED_DIR:-}" ]]; then
        CM_JSON=$(oc get configmap webhook-cert -n "${OPERATOR_NAMESPACE}" -o json 2>/dev/null | \
            jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
            2>/dev/null || true)
        [[ -n "${CM_JSON}" ]] && echo "${CM_JSON}" > "${SHARED_DIR}/webhook-cert-cm.json"
        SVC_JSON=$(oc get service validation-webhook -n "${OPERATOR_NAMESPACE}" -o json 2>/dev/null | \
            jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status, .spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies, .spec.ipFamilyPolicy)' \
            2>/dev/null || true)
        [[ -n "${SVC_JSON}" ]] && echo "${SVC_JSON}" > "${SHARED_DIR}/validation-webhook-svc.json"
        log "Resources saved to SHARED_DIR"
    fi
    log "Removing SSS-managed resources that block PKO adoption"
    oc delete configmap webhook-cert -n "${OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    oc delete service validation-webhook -n "${OPERATOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    cat <<EOF | oc apply -f -
apiVersion: package-operator.run/v1alpha1
kind: Package
metadata:
  name: ${CLUSTER_PACKAGE_NAME}
  namespace: ${OPERATOR_NAMESPACE}
  annotations:
    package-operator.run/collision-protection: None
spec:
  image: ${OPERATOR_PKO_IMAGE}
  config:
    image: ${OPERATOR_IMAGE}
    serviceca: "${SERVICE_CA}"
EOF

    # Wait for PKO to create the Deployment (up to 5 minutes)
    log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to exist..."
    for i in $(seq 1 30); do
        if oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
            log "Deployment exists"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} not found after 5 minutes"
            oc get package "${CLUSTER_PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
            oc get objectset -n "${OPERATOR_NAMESPACE}" 2>/dev/null | head -20 || true
            exit 1
        fi
        sleep 10
    done
fi

# Determine workload type for rollout. Read mode from SHARED_DIR if set.
INSTALL_MODE=""
[[ -n "${SHARED_DIR:-}" ]] && INSTALL_MODE=$(cat "${SHARED_DIR}/operator-e2e-mode" 2>/dev/null || true)

WORKLOAD_TYPE="deployment"
if [[ "${INSTALL_MODE}" == "daemonset-direct" ]]; then
    WORKLOAD_TYPE="daemonset"
fi

# Add CI pull secret to the workload's SA so pods can pull CI images.
if oc get secret ci-pull-secret -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
    SA_NAME=$(oc get "${WORKLOAD_TYPE}/${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "${OPERATOR_NAME}")
    if oc get sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        oc patch sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
        log "CI pull secret added to ServiceAccount ${SA_NAME}"
    fi
fi

# oc rollout restart ensures pods pick up the SA change and the new image.
oc rollout restart "${WORKLOAD_TYPE}/${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true

# oc rollout status waits for all updated replicas to be ready.
log "Waiting for ${OPERATOR_DEPLOYMENT_NAME} rollout to complete..."
if ! oc rollout status "${WORKLOAD_TYPE}/${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=10m; then
    log "ERROR: ${WORKLOAD_TYPE^} ${OPERATOR_DEPLOYMENT_NAME} did not roll out in time"
    oc get "${WORKLOAD_TYPE}/${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
    oc get pods -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
    exit 1
fi

log "${OPERATOR_NAME} ready in ${OPERATOR_NAMESPACE}"
