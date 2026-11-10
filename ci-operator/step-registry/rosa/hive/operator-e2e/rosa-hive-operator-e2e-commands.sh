#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") $*\033[0m" >&2; }

if [[ -z "${OPERATOR_NAME:-}" ]]; then
    log "ERROR: OPERATOR_NAME is required"
    exit 1
fi

if [[ -z "${BACKPLANE_CLUSTER_ID:-}" ]]; then
    log "ERROR: BACKPLANE_CLUSTER_ID is required"
    exit 1
fi

if [[ -z "${BACKPLANE_ELEVATE_REASON:-}" ]]; then
    log "ERROR: BACKPLANE_ELEVATE_REASON is required for hive e2e tests"
    exit 1
fi

# Install ocm-backplane CLI
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

if ! command -v ocm-backplane &>/dev/null; then
    log "Installing ocm-backplane v${BACKPLANE_CLI_VERSION}"
    curl -sfSL "https://github.com/openshift/backplane-cli/releases/download/v${BACKPLANE_CLI_VERSION}/ocm-backplane_${BACKPLANE_CLI_VERSION}_Linux_x86_64.tar.gz" \
        | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
    chmod +x "${BIN}/ocm-backplane"
fi

# Configure backplane proxy
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${BACKPLANE_PROXY_URL}" > "${HOME}/.config/backplane/config.json"

# Re-establish OCM login (each step is a separate pod)
set +x
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi
set -x

# Backplane login
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
ocm-backplane login "${BACKPLANE_CLUSTER_ID}"
log "Connected to $(oc whoami --show-server) as $(oc whoami)"

# Disable boilerplate JUnit (permission denied on /test-run-results/)
export DISABLE_JUNIT_REPORT=true

# Build ginkgo args
JUNIT_REPORT="${ARTIFACT_DIR}/junit-${OPERATOR_NAME}-e2e.xml"
GINKGO_ARGS=("--ginkgo.junit-report=${JUNIT_REPORT}" "--ginkgo.v")

if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.label-filter=${GINKGO_LABEL_FILTER}")
fi

if [[ -n "${GINKGO_FOCUS:-}" ]]; then
    GINKGO_ARGS+=("--ginkgo.focus=${GINKGO_FOCUS}")
fi

# Collect operator logs on exit
collect_operator_logs() {
    local ns="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
    if [[ -n "${ARTIFACT_DIR:-}" ]] && oc get namespace "${ns}" &>/dev/null; then
        for deploy in $(oc get deployment -n "${ns}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
            oc logs "deployment/${deploy}" -n "${ns}" --all-containers --tail=500 \
                > "${ARTIFACT_DIR}/${deploy}-logs.txt" 2>&1 || true
        done
        oc get events -n "${ns}" --sort-by='.lastTimestamp' \
            > "${ARTIFACT_DIR}/operator-namespace-events.txt" 2>&1 || true
    fi
}
trap 'collect_operator_logs; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM EXIT

# Dump an elevated kubeconfig with backplane-cluster-admin impersonation.
# ocm-backplane elevate wraps oc commands, so we use 'config view --raw'
# to capture the elevated kubeconfig to a file the e2e binary can use.
log "Dumping elevated backplane kubeconfig..."
ELEVATED_KUBECONFIG="$(mktemp /tmp/elevated-kubeconfig.XXXXXX)"
chmod 0600 "${ELEVATED_KUBECONFIG}"
set +x
if ! ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- \
    config view --raw --minify > "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: failed to dump elevated backplane kubeconfig"
    rm -f "${ELEVATED_KUBECONFIG}"
    exit 1
fi
set -x

if ! grep -q 'backplane-cluster-admin' "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: elevated kubeconfig missing backplane-cluster-admin impersonation"
    exit 1
fi

export KUBECONFIG="${ELEVATED_KUBECONFIG}"
log "Elevated access ready: $(oc whoami)"

# Run e2e binary with elevated kubeconfig
log "Running ${OPERATOR_NAME} e2e tests..."
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}" || {
    log "Tests failed. JUnit report at ${JUNIT_REPORT}"
    exit 1
}

log "Tests passed. JUnit report at ${JUNIT_REPORT}"
