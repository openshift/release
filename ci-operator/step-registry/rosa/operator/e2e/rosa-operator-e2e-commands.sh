#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

collect_operator_logs() {
    local ns="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
    local kube_cmd
    if command -v oc &>/dev/null; then
        kube_cmd="oc"
    elif command -v kubectl &>/dev/null; then
        kube_cmd="kubectl"
    else
        return
    fi
    if [[ -n "${ARTIFACT_DIR:-}" ]] && ${kube_cmd} get namespace "${ns}" &>/dev/null; then
        for deploy in $(${kube_cmd} get deployment -n "${ns}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
            ${kube_cmd} logs "deployment/${deploy}" -n "${ns}" --all-containers --tail=500 \
                > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        done
        ${kube_cmd} get events -n "${ns}" --sort-by='.lastTimestamp' \
            > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
    fi
}

trap 'collect_operator_logs; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM EXIT

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

# Get cluster access: prefer shared kubeconfig from provision step,
# fall back to backplane for persistent clusters
if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    log "Using kubeconfig from provision step"
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
elif [[ -n "${OPERATOR_E2E_CLUSTER_ID:-}" ]]; then
    # Log into OCM for backplane access
    SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
    SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
    OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

    if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
        log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
        ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
    elif [[ -n "${OCM_TOKEN}" ]]; then
        log "Logging into ${OCM_LOGIN_ENV} with offline token"
        ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
    else
        log "ERROR: No OCM credentials found in cluster profile"
        exit 1
    fi

    log "Getting kubeconfig for cluster ${OPERATOR_E2E_CLUSTER_ID} via backplane"
    ocm backplane login "${OPERATOR_E2E_CLUSTER_ID}"
else
    log "ERROR: No cluster access method available (no SHARED_DIR/kubeconfig or OPERATOR_E2E_CLUSTER_ID)"
    exit 1
fi

# Verify cluster access
if command -v oc &>/dev/null; then
    oc whoami
    log "Connected to cluster: $(oc whoami --show-server)"
else
    log "oc not available, skipping cluster verification (e2e binary uses kubeconfig directly)"
fi

# Wait for the operator deployment to exist before proceeding.
# When a Hive SyncSet applies late, the deployment may not be present yet.
DEPLOY_NS="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
DEPLOY_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"
DEPLOY_WAIT="${OPERATOR_DEPLOY_WAIT_SECONDS:-120}"
log "Waiting up to ${DEPLOY_WAIT}s for deployment/${DEPLOY_NAME} in ${DEPLOY_NS}"
DEPLOY_DEADLINE=$(( $(date +%s) + DEPLOY_WAIT ))
DEPLOY_FOUND=false
while [[ $(date +%s) -lt ${DEPLOY_DEADLINE} ]]; do
    if kubectl get deployment "${DEPLOY_NAME}" -n "${DEPLOY_NS}" &>/dev/null; then
        DEPLOY_FOUND=true
        break
    fi
    sleep 5
done
if [[ "${DEPLOY_FOUND}" != "true" ]]; then
    log "ERROR: Deployment ${DEPLOY_NAME} not found in ${DEPLOY_NS} after ${DEPLOY_WAIT}s"
    log "Diagnostic: resources in ${DEPLOY_NS}:"
    kubectl get all -n "${DEPLOY_NS}" 2>&1 || true
    log "Diagnostic: events in ${DEPLOY_NS}:"
    kubectl get events -n "${DEPLOY_NS}" --sort-by='.lastTimestamp' 2>&1 || true
    exit 1
fi
log "Deployment ${DEPLOY_NAME} found in ${DEPLOY_NS}"

# Set up port-forward if requested (e.g. for services like ocm-agent that
# need a local endpoint for e2e tests to reach the in-cluster service).
if [[ -n "${PORT_FORWARD_SVC:-}" ]]; then
    PF_NS="${PORT_FORWARD_SVC%%/*}"
    PF_SVC_PORT="${PORT_FORWARD_SVC#*/}"
    PF_SVC="${PF_SVC_PORT%%:*}"
    PF_PORT="${PF_SVC_PORT#*:}"
    # Wait for the service to exist before attempting port-forward.
    # After cleanup, PKO may still be re-deploying the service.
    log "Waiting up to 120s for service ${PF_SVC} to appear in ${PF_NS}"
    SVC_DEADLINE=$(( $(date +%s) + 120 ))
    SVC_FOUND=false
    while [[ $(date +%s) -lt ${SVC_DEADLINE} ]]; do
        if kubectl get svc "${PF_SVC}" -n "${PF_NS}" &>/dev/null; then
            SVC_FOUND=true
            break
        fi
        sleep 5
    done
    if [[ "${SVC_FOUND}" != "true" ]]; then
        log "ERROR: Service ${PF_SVC} not found in ${PF_NS} after 120s"
        log "Diagnostic: resources in ${PF_NS}:"
        kubectl get all -n "${PF_NS}" 2>&1 || true
        log "Diagnostic: OcmAgent resources:"
        kubectl get ocmagents -A 2>&1 || true
        exit 1
    fi
    log "Service ${PF_SVC} found in ${PF_NS}"
    log "Starting kubectl port-forward svc/${PF_SVC} ${PF_PORT}:${PF_PORT} -n ${PF_NS}"
    kubectl port-forward "svc/${PF_SVC}" "${PF_PORT}:${PF_PORT}" -n "${PF_NS}" &
    PF_PID=$!
    sleep 3
    if ! kill -0 "${PF_PID}" 2>/dev/null; then
        log "ERROR: port-forward failed to start"
        exit 1
    fi
    log "Port-forward running on localhost:${PF_PORT} (PID ${PF_PID})"
fi

# Disable the boilerplate runner's hardcoded JUnit path (/test-run-results/)
# which fails with permission denied. Our --ginkgo.junit-report flag handles JUnit output.
export DISABLE_JUNIT_REPORT=true

# Run the operator e2e tests
JUNIT_REPORT="${ARTIFACT_DIR}/junit-${OPERATOR_NAME}-e2e.xml"
GINKGO_ARGS=("--ginkgo.junit-report=${JUNIT_REPORT}" "--ginkgo.v")

if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.label-filter=${GINKGO_LABEL_FILTER}")
fi

if [[ -n "${GINKGO_FOCUS:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.focus=${GINKGO_FOCUS}")
fi

# Export the cluster ID so operator e2e tests can identify the target cluster
if [[ -f "${SHARED_DIR}/cluster-id" ]]; then
    export OCM_CLUSTER_ID
    OCM_CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
    log "OCM_CLUSTER_ID set to ${OCM_CLUSTER_ID}"
fi

# Export OCM credentials so operator e2e tests can interact with OCM API
if [[ -f "${CLUSTER_PROFILE_DIR}/sso-client-id" ]]; then
    export OCM_CLIENT_ID
    OCM_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id")
    log "OCM_CLIENT_ID set from cluster profile"
fi
if [[ -f "${CLUSTER_PROFILE_DIR}/sso-client-secret" ]]; then
    export OCM_CLIENT_SECRET
    OCM_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret")
    log "OCM_CLIENT_SECRET set from cluster profile"
fi

log "Running ${OPERATOR_NAME} e2e tests..."
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}" || {
    log "Tests failed. JUnit report at ${JUNIT_REPORT}"
    exit 1
}

log "Tests passed. JUnit report at ${JUNIT_REPORT}"
