#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

# Get cluster access: prefer shared kubeconfig from provision step,
# fall back to backplane for persistent clusters
if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
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
oc whoami
log "Connected to cluster: $(oc whoami --show-server)"

# Run the operator e2e tests
JUNIT_REPORT="${ARTIFACT_DIR}/junit-${OPERATOR_NAME}-e2e.xml"
GINKGO_FLAGS="--ginkgo.junit-report=${JUNIT_REPORT} --ginkgo.v"

if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    GINKGO_FLAGS="${GINKGO_FLAGS} --ginkgo.label-filter=${GINKGO_LABEL_FILTER}"
fi

log "Running ${OPERATOR_NAME} e2e tests..."
/usr/local/bin/e2e.test ${GINKGO_FLAGS} || {
    log "Tests failed. JUnit report at ${JUNIT_REPORT}"
    exit 1
}

log "Tests passed. JUnit report at ${JUNIT_REPORT}"
