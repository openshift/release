#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

retry_with_backoff() {
    local max_attempts=3
    local -a delays=(10 30 60)
    local attempt
    local rc

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        log "Attempt ${attempt}/${max_attempts}: $*"
        rc=0
        "$@" || rc=$?
        if (( rc == 0 )); then
            return 0
        fi
        if (( attempt < max_attempts )); then
            log "Command failed (exit code ${rc}), retrying in ${delays[$((attempt-1))]}s..."
            sleep "${delays[$((attempt-1))]}"
        fi
    done
    log "ERROR: Command failed after ${max_attempts} attempts"
    return "${rc}"
}

if [[ -z "${BACKPLANE_CLUSTER_ID:-}" ]]; then
    log "ERROR: BACKPLANE_CLUSTER_ID is required"
    exit 1
fi

# Install ocm-backplane CLI if not present
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

if ! command -v ocm-backplane &>/dev/null; then
    log "Installing ocm-backplane v${BACKPLANE_CLI_VERSION}"
    curl -sfSL "https://github.com/openshift/backplane-cli/releases/download/v${BACKPLANE_CLI_VERSION}/ocm-backplane_${BACKPLANE_CLI_VERSION}_Linux_x86_64.tar.gz" \
        | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
    chmod +x "${BIN}/ocm-backplane"
fi

log "ocm: $(ocm version 2>&1 | head -1), backplane: $(ocm-backplane version 2>&1 | head -1)"

# Configure backplane proxy for corp network access from build farm
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${BACKPLANE_PROXY_URL}" > "${HOME}/.config/backplane/config.json"
log "Configured backplane proxy: ${BACKPLANE_PROXY_URL}"

# OCM login using cluster profile credentials
set +x
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi
set -x

# Backplane login writes kubeconfig to SHARED_DIR for downstream steps
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Backplane login to ${BACKPLANE_CLUSTER_ID}"

# Quick connectivity probe for diagnostic output (never fails the job)
log "Connectivity probe: testing backplane API reachability via proxy"
if curl -sSf --max-time 10 --proxy "${BACKPLANE_PROXY_URL}" "https://api.openshift.com/" &>/dev/null; then
    log "Probe: API endpoint reachable through proxy"
else
    log "Probe: API endpoint unreachable through proxy (informational only, proceeding with login)"
fi

retry_with_backoff ocm-backplane login "${BACKPLANE_CLUSTER_ID}"

oc whoami
log "Connected to $(oc whoami --show-server) via backplane"

if [[ -n "${BACKPLANE_ELEVATE_REASON:-}" ]]; then
    ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- whoami
    log "Elevated access verified (note: elevation is per-command, downstream steps re-elevate)"
fi
