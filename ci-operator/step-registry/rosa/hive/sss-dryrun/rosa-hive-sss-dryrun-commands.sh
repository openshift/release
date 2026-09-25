#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Server-side dry-run validation of MCC SelectorSyncSet templates.
# Uses the backplane kubeconfig from the rosa-hive-backplane-login pre step,
# then elevates access for the dry-run apply.

log() { echo -e "\033[1m$(date '+%d-%m-%YT%H:%M:%S') $*\033[0m"; }

# Use the kubeconfig from the pre step (rosa-hive-backplane-login)
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Using backplane kubeconfig from pre step: ${KUBECONFIG}"
log "Target server: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
log "Authenticated as: $(oc whoami 2>/dev/null || echo 'unknown')"

# Generate SelectorSyncSet templates
log "Generating SelectorSyncSet templates via make"
export IN_CONTAINER=true
make

# Fix apiVersion: the .tmpl uses "v1" which oc process doesn't recognize;
# it needs "template.openshift.io/v1"
TEMPLATE="hack/00-osd-managed-cluster-config-integration.yaml.tmpl"
log "Fixing apiVersion in ${TEMPLATE}"
sed -i 's|^apiVersion: v1$|apiVersion: template.openshift.io/v1|' "${TEMPLATE}"

# Process template with integration parameters (dummy values for schema validation)
PROCESSED="${ARTIFACT_DIR}/processed-sss.yaml"
log "Processing ${TEMPLATE} (ENV=int) with integration parameters"
oc process --local -f "${TEMPLATE}" \
    -p ENV=int \
    -p IMAGE_TAG=latest \
    -p REPO_NAME=managed-cluster-config \
    -p TELEMETER_SERVER_URL=https://telemeter.example.com \
    -p OCM_BASE_URL=https://api.example.com \
    -p CONSOLE_BASE_URL=https://console.example.com \
    -p SREP_LEGAL_ENTITY_ID=dummy-legal-entity-id \
    -p LOG_LINKING_ENTITY_IDS=dummy-log-linking-id \
    -p 'ALLOWED_CIDR_BLOCKS=10.0.0.0/8' \
    -p 'ROUTER_REPLICA_CLUSTER_IDS=["dummy-cluster-id"]' \
    -p 'ROUTER_REPLICA_ORG_IDS=["dummy-org-id"]' \
    -p SEGMENT_API_KEY=dummy-segment-api-key \
    -p OBSERVATORIUM_URL=https://observatorium.example.com \
    -o yaml > "${PROCESSED}"

log "Processed template saved to ${PROCESSED}"

# Install ocm-backplane CLI for elevation (the pre step's image may not be this pod)
BACKPLANE_CLI_VERSION="${BACKPLANE_CLI_VERSION:-0.11.0}"
log "Installing ocm-backplane v${BACKPLANE_CLI_VERSION}"
BIN_DIR="${HOME}/bin"
mkdir -p "${BIN_DIR}"
curl -sSfL "https://github.com/openshift/backplane-cli/releases/download/v${BACKPLANE_CLI_VERSION}/ocm-backplane_${BACKPLANE_CLI_VERSION}_Linux_x86_64.tar.gz" \
    | tar xzf - -C "${BIN_DIR}" ocm-backplane
export PATH="${BIN_DIR}:${PATH}"

# Configure proxy for backplane access
BACKPLANE_PROXY_URL="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
mkdir -p ~/.config/backplane
echo "{\"proxy-url\":\"${BACKPLANE_PROXY_URL}\"}" > ~/.config/backplane/config.json
export HTTPS_PROXY="${BACKPLANE_PROXY_URL}"

# OCM login (needed for ocm-backplane elevate token)
SSO_CLIENT_ID=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/sso-client-id 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/sso-client-secret 2>/dev/null || true)
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-production}"
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "OCM login for elevation token"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
else
    OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token 2>/dev/null || true)
    if [[ -n "${OCM_TOKEN}" ]]; then
        log "OCM login (token) for elevation"
        ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
    else
        log "ERROR: No OCM credentials found for elevation"
        exit 1
    fi
fi

# Backplane login to establish session for elevation (writes to a temp kubeconfig,
# NOT overwriting the pre step's kubeconfig)
BP_KUBECONFIG=$(mktemp /tmp/bp-kubeconfig.XXXXXX)
log "Backplane login for elevation session"
KUBECONFIG="${BP_KUBECONFIG}" ocm-backplane login "${BACKPLANE_CLUSTER_ID}"

# Dump elevated kubeconfig (operator-e2e proven pattern)
log "Dumping elevated backplane kubeconfig..."
ELEVATED_KUBECONFIG=$(mktemp /tmp/elevated-kubeconfig.XXXXXX)
chmod 0600 "${ELEVATED_KUBECONFIG}"
if ! KUBECONFIG="${BP_KUBECONFIG}" ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- \
    config view --raw --minify > "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: failed to dump elevated backplane kubeconfig"
    rm -f "${ELEVATED_KUBECONFIG}" "${BP_KUBECONFIG}"
    exit 1
fi

if ! grep -q 'backplane-cluster-admin' "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: elevated kubeconfig missing backplane-cluster-admin impersonation"
    exit 1
fi

export KUBECONFIG="${ELEVATED_KUBECONFIG}"
log "Elevated as: $(oc whoami 2>/dev/null || echo 'unknown')"

# Server-side dry-run apply
log "Server-side dry-run apply of processed SelectorSyncSets"
oc apply --dry-run=server -f "${PROCESSED}"

log "All SelectorSyncSets passed server-side dry-run validation"

# Cleanup
rm -f "${ELEVATED_KUBECONFIG}" "${BP_KUBECONFIG}"
