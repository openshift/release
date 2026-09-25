#!/bin/bash
# Server-side dry-run validation of MCC SelectorSyncSet templates
# against a Hive cluster via backplane.
#
# Parameter values: dummy placeholder values (not real integration IDs,
# keys, or internal URLs). These only need to be valid-format for
# server-side schema validation of the SelectorSyncSets.

set -o nounset
set -o errexit
set -o pipefail
# Keep tracing disabled while handling credentials and internal endpoints.
set +x

log() { echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") $*\033[0m" >&2; }

# ---- Install CLI tools (each step is a separate pod) ----
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

if ! command -v ocm &>/dev/null; then
    log "Installing ocm CLI"
    curl -sfSL "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" -o "${BIN}/ocm"
    chmod +x "${BIN}/ocm"
fi

if ! command -v ocm-backplane &>/dev/null; then
    log "Installing ocm-backplane v${BACKPLANE_CLI_VERSION}"
    curl -sfSL "https://github.com/openshift/backplane-cli/releases/download/v${BACKPLANE_CLI_VERSION}/ocm-backplane_${BACKPLANE_CLI_VERSION}_Linux_x86_64.tar.gz" \
        | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
    chmod +x "${BIN}/ocm-backplane"
fi

# ---- Configure backplane proxy ----
mkdir -p "${HOME}/.config/backplane"
printf '{"proxy-url":"%s"}\n' "${BACKPLANE_PROXY_URL}" > "${HOME}/.config/backplane/config.json"

# ---- OCM login using cluster profile credentials ----
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM via SSO"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}" >/dev/null 2>&1
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM via token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}" >/dev/null 2>&1
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

# ---- Backplane login ----
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Logging into the cluster via backplane"
ocm-backplane login "${BACKPLANE_CLUSTER_ID}" >/dev/null 2>&1

# ---- Generate SSS template ----
log "Generating SelectorSyncSet template via make"
export IN_CONTAINER=true
make

# ---- Process integration template + server-side dry-run ----
# The .tmpl is a kind: Template needing oc process. All three env files are
# identical, so only the integration one is processed. See saas config:
# data/services/osd-operators/cicd/saas/saas-managed-cluster-config.yaml
#
# The template uses apiVersion: v1 which oc process doesn't register;
# fix up to template.openshift.io/v1 for local processing.
TEMPLATE="hack/00-osd-managed-cluster-config-integration.yaml.tmpl"
FIXED_TEMPLATE="${ARTIFACT_DIR}/template-fixed.yaml"
PROCESSED="${ARTIFACT_DIR}/processed-sss.yaml"

sed '1s/apiVersion: v1/apiVersion: template.openshift.io\/v1/' "${TEMPLATE}" > "${FIXED_TEMPLATE}"

log "Processing ${TEMPLATE} (ENV=int) with integration parameters"
oc process --local --ignore-unknown-parameters=true -f "${FIXED_TEMPLATE}" \
    -p ENV=int \
    -p IMAGE_TAG=latest \
    -p REPO_NAME=managed-cluster-config \
    -p TELEMETER_SERVER_URL=https://telemeter.example.com \
    -p OCM_BASE_URL=https://api.example.com \
    -p CONSOLE_BASE_URL=https://console.example.com \
    -p SREP_LEGAL_ENTITY_ID=dummy-legal-entity-id \
    -p LOG_LINKING_ENTITY_IDS=dummy-log-entity-id \
    -p 'ALLOWED_CIDR_BLOCKS=10.0.0.0/8' \
    -p 'ROUTER_REPLICA_CLUSTER_IDS=["dummy-cluster-id"]' \
    -p 'ROUTER_REPLICA_ORG_IDS=["dummy-org-id"]' \
    -p SEGMENT_API_KEY=dummy-segment-api-key \
    -p OBSERVATORIUM_URL=https://observatorium.example.com \
    -o yaml > "${PROCESSED}"

# Diagnostics: verify pre-elevate cluster context
log "Diagnostic: pre-elevate KUBECONFIG=${KUBECONFIG}"
log "Diagnostic: pre-elevate server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'unknown')"
log "Diagnostic: pre-elevate whoami=$(oc whoami 2>&1 || echo 'failed')"

# Dump elevated kubeconfig (proven operator-e2e pattern)
log "Dumping elevated backplane kubeconfig..."
ELEVATED_KUBECONFIG="$(mktemp /tmp/elevated-kubeconfig.XXXXXX)"
chmod 0600 "${ELEVATED_KUBECONFIG}"
if ! ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- \
    config view --raw --minify > "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: failed to dump elevated backplane kubeconfig"
    rm -f "${ELEVATED_KUBECONFIG}"
    exit 1
fi

if ! grep -q 'backplane-cluster-admin' "${ELEVATED_KUBECONFIG}"; then
    log "ERROR: elevated kubeconfig missing backplane-cluster-admin impersonation"
    exit 1
fi

export KUBECONFIG="${ELEVATED_KUBECONFIG}"

# Diagnostics: verify target cluster and CRD availability
log "Diagnostic: KUBECONFIG=${KUBECONFIG}"
log "Diagnostic: server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'unknown')"
log "Diagnostic: user=$(oc whoami 2>&1 || echo 'whoami failed')"
log "Diagnostic: show-server=$(oc whoami --show-server 2>&1 || echo 'show-server failed')"
log "Diagnostic: api-resources (hive)=$(oc api-resources 2>/dev/null | grep -i hive || echo 'no hive CRDs found')"
log "Diagnostic: raw /apis check=$(oc get --raw /apis 2>&1 | grep -o 'hive.openshift.io' || echo 'hive.openshift.io not in /apis')"

log "Server-side dry-run apply of processed SelectorSyncSets"
oc apply --dry-run=server -f "${PROCESSED}"

log "SSS server-side dry-run validation passed"
