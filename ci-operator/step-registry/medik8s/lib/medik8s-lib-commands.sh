#!/bin/bash
set -eu -o pipefail

cat <<'MEDIK8S_LIB_EOF' > "${SHARED_DIR}/medik8s-lib.sh"
# medik8s shared library — sourced by medik8s step-registry steps.
# Written by the medik8s-lib ref step; do not edit directly.

GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
GITLAB_PROJECT_NAME="dragonfly/rhwa-fbc"
GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"
FBC_IMAGE_REPO="quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc"
FBC_IMAGE_PREFIX="rhwa-fbc"
QUAY_REPO_PATH="redhat-user-workloads/rhwa-tenant/rhwa-fbc"

MCP_CONFIG_JSONPATH='{range .items[*]}{.metadata.name}={.status.configuration.name}{"\n"}{end}'

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

run() {
    log "running: $*"
    "$@"
}

set_proxy() {
    # shellcheck disable=SC1090
    [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
        log "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    }
    return 0
}

resolve_commit_sha() {
    if [[ -n "$FBC_COMMIT_SHA" ]]; then
        log "Using provided FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
        return 0
    fi

    local encoded_ref
    encoded_ref=$(jq -rn --arg ref "$GIT_REF" '$ref | @uri') || encoded_ref="$GIT_REF"

    log "Resolving latest commit from ${GITLAB_PROJECT_NAME} ${GIT_REF} ref..."
    FBC_COMMIT_SHA=$(curl -sSf --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 30 \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/repository/commits/${encoded_ref}" | jq -r .id) || true

    if [[ -z "$FBC_COMMIT_SHA" || "$FBC_COMMIT_SHA" == "null" ]]; then
        log "ERROR: Failed to resolve rhwa-fbc commit SHA from GitLab API"
        exit 1
    fi

    log "Resolved FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
}

verify_fbc_image() {
    local image_name="${FBC_IMAGE_PREFIX}-${OCP_VERSION}"
    local fbc_image="${FBC_IMAGE_REPO}/${image_name}:${FBC_COMMIT_SHA}"
    log "Verifying FBC image exists: $fbc_image"

    if ! curl -sSf -o /dev/null --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
        "https://quay.io/v2/${QUAY_REPO_PATH}/${image_name}/manifests/${FBC_COMMIT_SHA}" \
        -H "Accept: application/vnd.oci.image.index.v1+json" 2>/dev/null; then
        if [[ "$FBC_SHA_PINNED" == "true" ]]; then
            log "ERROR: Pinned FBC image not found: ${fbc_image}"
            log "The explicitly provided FBC_COMMIT_SHA does not have a corresponding image on Quay"
            exit 1
        fi

        log "WARNING: FBC image not found for commit ${FBC_COMMIT_SHA}"
        log "Falling back to listing available tags..."

        local fallback_tag
        fallback_tag=$(curl -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
            "https://quay.io/api/v1/repository/${QUAY_REPO_PATH}/${image_name}/tag/?limit=50&onlyActiveTags=true" 2>/dev/null \
            | jq -r '.tags[].name' \
            | grep -E '^[0-9a-f]{40}$' \
            | tail -1) || true

        if [[ -n "$fallback_tag" ]]; then
            log "Using fallback tag (arbitrary valid commit): $fallback_tag"
            FBC_COMMIT_SHA="$fallback_tag"
        else
            log "ERROR: No valid FBC image tags found"
            exit 1
        fi
    fi

    log "FBC image verified: ${FBC_IMAGE_REPO}/${image_name}:${FBC_COMMIT_SHA}"
}

wait_for_mcp_rollout() {
    local mcp_configs_before="$1"

    log "Waiting for MachineConfigPool rollout..."
    local mcp_changed=false
    for i in $(seq 1 30); do
        sleep 10
        local mcp_configs_after
        mcp_configs_after=$(oc get mcp -o jsonpath="$MCP_CONFIG_JSONPATH" 2>/dev/null || true)
        if [[ "$mcp_configs_before" != "$mcp_configs_after" ]]; then
            log "MCP rendered config changed:"
            log "  before: $mcp_configs_before"
            log "  after:  $mcp_configs_after"
            mcp_changed=true
            break
        fi
        log "  waiting for MCP config change (${i}/30)..."
    done

    if [[ "$mcp_changed" == "true" ]]; then
        oc wait mcp --all --for=condition=Updated --timeout=20m || {
            log "WARNING: MCP not fully updated after 20m, proceeding anyway"
            run oc get mcp
        }
    else
        log "WARNING: No MCP rendered config change detected after 5m — IDMS may not have triggered a rollout, proceeding"
    fi
}

ensure_marketplace() {
    log "Ensuring openshift-marketplace namespace and labels..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF
}

wait_for_catalogsource() {
    log "Waiting for CatalogSource ${CATALOG_SOURCE_NAME} to be READY..."
    local -i deadline=$(( SECONDS + 600 ))
    local status=""

    while (( SECONDS < deadline )); do
        status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" \
            -o=jsonpath="{.status.connectionState.lastObservedState}" 2>/dev/null || true)
        log "  status: ${status:-pending}"
        [[ "$status" == "READY" ]] && {
            log "CatalogSource ${CATALOG_SOURCE_NAME} is READY"
            return 0
        }
        sleep 20
    done

    log "ERROR: CatalogSource not READY after 600s"
    log "--- Debug info ---"
    run oc get pods -o wide -n openshift-marketplace
    run oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" -o yaml
    run oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE_NAME" -o yaml
    log "--- Marketplace events ---"
    oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    run oc get mcp,node
    return 1
}
MEDIK8S_LIB_EOF

echo "medik8s-lib.sh written to ${SHARED_DIR}"
