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

log "Installing ${OPERATOR_NAME} via PKO ClusterPackage (mcvw variant)"
log "  ClusterPackage: ${CLUSTER_PACKAGE_NAME}"
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
fi

# Remove existing ClusterPackage if present (safe on ephemeral clusters only)
if oc get clusterpackage "${OPERATOR_NAME}" &>/dev/null; then
    log "Removing existing ClusterPackage ${OPERATOR_NAME}"
    oc delete clusterpackage "${OPERATOR_NAME}" --timeout=120s || true
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
fi

if [[ "${CLUSTER_PACKAGE_NAME}" != "${OPERATOR_NAME}" ]]; then
    RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
    if [[ -n "${RESULT}" ]]; then
        log "Removing leftover e2e ClusterPackage ${CLUSTER_PACKAGE_NAME}"
        oc delete clusterpackage "${CLUSTER_PACKAGE_NAME}" --timeout=60s || true
        for i in $(seq 1 12); do
            RESULT=$(oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" --ignore-not-found -o name 2>&1) || true
            if [[ -z "${RESULT}" ]]; then break; fi
            if [[ $i -eq 12 ]]; then
                oc patch clusterpackage "${CLUSTER_PACKAGE_NAME}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            fi
            sleep 5
        done
    fi
fi

# Fetch the cluster service CA. MCVW's PKO package requires serviceca in the
# ClusterPackage config to populate the caBundle field in ValidatingWebhookConfigurations.
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

# Create the ClusterPackage CR with serviceca config
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
    namespace: ${OPERATOR_NAMESPACE}
    serviceca: "${SERVICE_CA}"
EOF

# Save ClusterPackage name for the cleanup step
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

SA_PATCHED=""
log "Waiting for deployment ${OPERATOR_DEPLOYMENT_NAME} to be ready..."
for attempt in $(seq 1 30); do
    if ! oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        sleep 10
        continue
    fi

    if [[ -z "${SA_PATCHED}" ]] && oc get secret ci-pull-secret -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
        SA_NAME=$(oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "${OPERATOR_NAME}")
        if oc get sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
            oc patch sa "${SA_NAME}" -n "${OPERATOR_NAMESPACE}" \
                --type json -p '[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ci-pull-secret"}}]' 2>/dev/null || true
            log "CI pull secret added to ServiceAccount ${SA_NAME}"
            oc delete pods -n "${OPERATOR_NAMESPACE}" -l app="${OPERATOR_DEPLOYMENT_NAME}" 2>/dev/null || true
            SA_PATCHED=1
        fi
    fi

    if oc wait deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" \
        --for=condition=Available --timeout=30s 2>/dev/null; then
        break
    fi

    if [[ ${attempt} -eq 30 ]]; then
        log "ERROR: Deployment ${OPERATOR_DEPLOYMENT_NAME} not ready after 5 minutes"
        oc get deployment "${OPERATOR_DEPLOYMENT_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml 2>/dev/null || true
        oc get pods -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true
        exit 1
    fi
done

log "${OPERATOR_NAME} installed and ready in ${OPERATOR_NAMESPACE}"
