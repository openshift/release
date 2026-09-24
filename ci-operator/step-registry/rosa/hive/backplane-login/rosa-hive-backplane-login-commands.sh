#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
# Keep tracing disabled while handling credentials and internal endpoints.
set +x

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

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
log "Configured backplane proxy"

# OCM login using cluster profile credentials
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" >/dev/null 2>&1
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM with offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}" >/dev/null 2>&1
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

# Backplane login writes kubeconfig to SHARED_DIR for downstream steps
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Logging into the cluster via backplane"
ocm-backplane login "${BACKPLANE_CLUSTER_ID}" >/dev/null 2>&1

oc whoami >/dev/null 2>&1
log "Connected to the cluster via backplane"

if [[ -n "${BACKPLANE_ELEVATE_REASON:-}" ]]; then
    ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- whoami >/dev/null 2>&1
    log "Elevated access verified (note: elevation is per-command, downstream steps re-elevate)"
fi
