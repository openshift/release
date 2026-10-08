#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM EXIT

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Get cluster access: prefer shared kubeconfig from provision step,
# fall back to backplane for persistent clusters
if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    log "Using kubeconfig from provision step"
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
elif [[ -n "${CAD_E2E_CLUSTER_ID:-}" ]]; then
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

    log "Getting kubeconfig via backplane"
    ocm backplane login "${CAD_E2E_CLUSTER_ID}"
else
    log "ERROR: No cluster access method available (no SHARED_DIR/kubeconfig or CAD_E2E_CLUSTER_ID)"
    exit 1
fi

# Verify cluster access (do not log identity or API URL — sensitive data)
if command -v oc &>/dev/null; then
    if oc whoami >/dev/null 2>&1; then
        log "Cluster access verified"
    else
        log "ERROR: Unable to access cluster"
        exit 1
    fi
else
    log "oc not available, skipping cluster verification (e2e binary uses kubeconfig directly)"
fi

# Export the cluster ID so CAD e2e tests can identify the target cluster
if [[ -f "${SHARED_DIR}/cluster-id" ]]; then
    export OCM_CLUSTER_ID
    OCM_CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
    log "OCM_CLUSTER_ID set from SHARED_DIR/cluster-id"
fi

# Export OCM credentials so CAD e2e tests can interact with OCM API
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

# Export PagerDuty routing key for CAD alert tests
if [[ -f "${CLUSTER_PROFILE_DIR}/cad-pagerduty-routing-key" ]]; then
    export CAD_PAGERDUTY_ROUTING_KEY
    CAD_PAGERDUTY_ROUTING_KEY=$(cat "${CLUSTER_PROFILE_DIR}/cad-pagerduty-routing-key")
    log "CAD_PAGERDUTY_ROUTING_KEY set from cluster profile"
elif [[ -n "${CAD_PAGERDUTY_ROUTING_KEY:-}" ]]; then
    log "CAD_PAGERDUTY_ROUTING_KEY set from env var"
fi

# Disable the boilerplate runner's hardcoded JUnit path (/test-run-results/)
# which fails with permission denied. Our --ginkgo.junit-report flag handles JUnit output.
export DISABLE_JUNIT_REPORT=true

# Run the CAD e2e tests
JUNIT_REPORT="${ARTIFACT_DIR}/junit-cad-e2e.xml"
GINKGO_ARGS=("--ginkgo.junit-report=${JUNIT_REPORT}" "--ginkgo.v")

if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.label-filter=${GINKGO_LABEL_FILTER}")
fi

if [[ -n "${GINKGO_FOCUS:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.focus=${GINKGO_FOCUS}")
fi

log "Running CAD e2e tests..."
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}" || {
    log "Tests failed. JUnit report at ${JUNIT_REPORT}"
    exit 1
}

log "Tests passed. JUnit report at ${JUNIT_REPORT}"
