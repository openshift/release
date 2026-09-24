#!/bin/bash
# Health check: verifies all SelectorSyncSets, SyncSets, and ClusterSyncs
# are green (no failures) across multiple Hive shards.
set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

# ---- Install CLI tools ----
BIN="${HOME}/bin"; mkdir -p "${BIN}"; export PATH="${BIN}:${PATH}"
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

# ---- OCM login ----
set +x
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "OCM login (${OCM_LOGIN_ENV}) via SSO"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "OCM login (${OCM_LOGIN_ENV}) via token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials in cluster profile"; exit 1
fi
set -x

# ---- Check each Hive shard ----
OVERALL_FAILURES=0
SHARD_COUNT=0
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

for CLUSTER_ID in $(echo "${BACKPLANE_CLUSTER_IDS}" | tr ',' ' '); do
    SHARD_COUNT=$((SHARD_COUNT + 1))
    log "=== Checking shard: ${CLUSTER_ID} ==="

    # Backplane login
    ocm-backplane login "${CLUSTER_ID}"
    SHARD_NAME=$(oc whoami --show-server 2>/dev/null || echo "${CLUSTER_ID}")
    log "Connected to ${SHARD_NAME}"

    # Fetch ClusterSync resources with elevated access
    CLUSTERSYNC_JSON="${ARTIFACT_DIR:-/tmp}/clustersync-${CLUSTER_ID}.json"
    ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- \
        get clustersync -A -o json > "${CLUSTERSYNC_JSON}"

    TOTAL_SYNCS=$(jq '.items | length' "${CLUSTERSYNC_JSON}")
    log "Found ${TOTAL_SYNCS} ClusterSync resources"

    # Check for Failed conditions
    FAILED_CONDITIONS=$(jq -r '
        .items[] |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        (.status.conditions[]? | select(.type == "Failed" and .status == "True") |
            "\($ns)/\($name): Failed condition: \(.message // "no message")")
    ' "${CLUSTERSYNC_JSON}")

    # Check for SelectorSyncSet failures
    SSS_FAILURES=$(jq -r '
        .items[] |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        (.status.selectorSyncSets[]? | select(.result == "Failure") |
            "\($ns)/\($name): SelectorSyncSet \(.name) FAILED: \(.failureMessage // "no message")")
    ' "${CLUSTERSYNC_JSON}")

    # Check for SyncSet failures
    SS_FAILURES=$(jq -r '
        .items[] |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        (.status.syncSets[]? | select(.result == "Failure") |
            "\($ns)/\($name): SyncSet \(.name) FAILED: \(.failureMessage // "no message")")
    ' "${CLUSTERSYNC_JSON}")

    # Aggregate
    SHARD_FAILURES=""
    [[ -n "${FAILED_CONDITIONS}" ]] && SHARD_FAILURES="${SHARD_FAILURES}${FAILED_CONDITIONS}\n"
    [[ -n "${SSS_FAILURES}" ]] && SHARD_FAILURES="${SHARD_FAILURES}${SSS_FAILURES}\n"
    [[ -n "${SS_FAILURES}" ]] && SHARD_FAILURES="${SHARD_FAILURES}${SS_FAILURES}\n"

    if [[ -n "${SHARD_FAILURES}" ]]; then
        FAIL_COUNT=$(echo -e "${SHARD_FAILURES}" | grep -c . || true)
        log "FAIL: ${FAIL_COUNT} failure(s) on shard ${CLUSTER_ID}:"
        echo -e "${SHARD_FAILURES}"
        OVERALL_FAILURES=$((OVERALL_FAILURES + FAIL_COUNT))
    else
        log "PASS: All ${TOTAL_SYNCS} ClusterSyncs green on shard ${CLUSTER_ID}"
    fi
done

log "=== Summary: checked ${SHARD_COUNT} shards, ${OVERALL_FAILURES} total failures ==="

if [[ ${OVERALL_FAILURES} -gt 0 ]]; then
    log "ERROR: ${OVERALL_FAILURES} failure(s) detected across Hive shards"
    exit 1
fi

log "All Hive shards healthy — SelectorSyncSets, SyncSets, and ClusterSyncs are green"
