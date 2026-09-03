#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-validation-webhook}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-validation-webhook}"
CLUSTER_PACKAGE_NAME="${CLUSTER_PACKAGE_NAME:-${OPERATOR_NAME}-e2e-test}"

log "Installing ${OPERATOR_NAME} via PKO Package (mcvw variant)"
log "  PKO image: ${OPERATOR_PKO_IMAGE}"
log "  Operator image: ${OPERATOR_IMAGE}"
log "  Namespace: ${OPERATOR_NAMESPACE}"

# Add CI build cluster registry credentials to the cluster's global pull
# secret so both PKO and nodes can pull CI-built images.
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
        else
            log "  Pull secret conflict (attempt ${attempt}), retrying..."
            sleep 1
        fi
    done

    echo "${MERGED_PS}" > /tmp/merged-pull-secret.json
    oc create secret docker-registry ci-pull-secret \
        -n openshift-package-operator \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    oc patch sa package-operator -n openshift-package-operator \
        --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true

    oc rollout restart deployment -n openshift-package-operator 2>/dev/null || true
    oc rollout status deployment -n openshift-package-operator --timeout=120s 2>/dev/null || true
    log "PKO restarted with CI pull secret"

    oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
    oc create secret docker-registry ci-pull-secret \
        -n "${OPERATOR_NAMESPACE}" \
        --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json \
        --dry-run=client -o yaml | oc apply -f -
    log "CI pull secret added to operator namespace ${OPERATOR_NAMESPACE}"
else
    log "WARNING: Could not get CI registry credentials, PKO may fail to pull images"
    oc create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
fi

# Fetch the cluster service CA. MCVW's PKO package requires serviceca in the
# Package config to populate the caBundle field in ValidatingWebhookConfigurations.
log "Fetching cluster service CA"
SERVICE_CA=$(oc get configmap openshift-service-ca.crt -n openshift-config \
    -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | base64 -w0 2>/dev/null || \
    oc get configmap openshift-service-ca.crt -n openshift-config \
    -o jsonpath='{.data.service-ca\.crt}' | base64)

if [[ -z "${SERVICE_CA}" ]]; then
    log "ERROR: Could not fetch service CA from openshift-service-ca.crt configmap"
    exit 1
fi
log "Service CA fetched (${#SERVICE_CA} bytes base64)"

# MCVW is already deployed as a platform component on ROSA lease clusters.
# Patch the existing Package to use the CI-built images instead of creating a
# new conflicting Package. PKO refuses to adopt objects (webhook-cert ConfigMap,
# etc.) that are already managed by another Package revision.
log "Looking for existing Package in ${OPERATOR_NAMESPACE}"
EXISTING_PACKAGE=$(oc get package -n "${OPERATOR_NAMESPACE}" \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)

if [[ -n "${EXISTING_PACKAGE}" ]]; then
    log "Found existing Package '${EXISTING_PACKAGE}', patching to CI images"
    ORIG_PKO_IMAGE=$(oc get package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.image}')
    ORIG_OP_IMAGE=$(oc get package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.config.image}')
    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "${EXISTING_PACKAGE}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${OPERATOR_NAMESPACE}" > "${SHARED_DIR}/operator-e2e-namespace"
        echo "${ORIG_PKO_IMAGE}" > "${SHARED_DIR}/operator-e2e-orig-pko-image"
        echo "${ORIG_OP_IMAGE}" > "${SHARED_DIR}/operator-e2e-orig-op-image"
    fi
    oc patch package "${EXISTING_PACKAGE}" -n "${OPERATOR_NAMESPACE}" \
        --type merge -p \
        "{\"spec\":{\"image\":\"${OPERATOR_PKO_IMAGE}\",\"config\":{\"image\":\"${OPERATOR_IMAGE}\",\"serviceca\":\"${SERVICE_CA}\"}}}"
    CLUSTER_PACKAGE_NAME="${EXISTING_PACKAGE}"
    log "Package '${EXISTING_PACKAGE}' patched to CI images"
else
    log "No existing Package found, creating new Package ${CLUSTER_PACKAGE_NAME}"
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
    if [[ -n "${SHARED_DIR:-}" ]]; then
        echo "${CLUSTER_PACKAGE_NAME}" > "${SHARED_DIR}/operator-e2e-clusterpackage"
        echo "${OPERATOR_NAMESPACE}" > "${SHARED_DIR}/operator-e2e-namespace"
    fi
fi

# Wait for PKO to create the Deployment from the Package (up to 5 minutes)
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

# Add CI pull secret to the deployment's SA so pods can pull from the CI registry.
# Then trigger a rollout so the new pods pick up the SA change.
if oc get secret ci-pull-secret -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
    SA_NAME=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "${OPERATOR_NAME}")
    if oc get sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        oc patch sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" \
            --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
        log "CI pull secret added to ServiceAccount ${SA_NAME}"
    fi
    oc rollout restart deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
fi

# oc rollout status waits until all updated replicas are ready -- unlike
# --for=condition=Available which can return true with 0 ready pods when
# maxUnavailable covers all replicas.
log "Waiting for ${OPERATOR_DEPLOYMENT_NAME} rollout to complete..."
if ! oc rollout status deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=10m; then
    log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} did not roll out in time"
    oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
    oc get pods -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
    oc get package "${CLUSTER_PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
    exit 1
fi

log "${OPERATOR_NAME} installed and ready in ${OPERATOR_NAMESPACE}"
