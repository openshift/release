#!/bin/bash
set -eu -o pipefail

cat <<'MEDIK8S_LIB_EOF' > "${SHARED_DIR}/medik8s-lib.sh"
# medik8s shared library — sourced by medik8s step-registry steps.
# Written by the medik8s-lib ref step; do not edit directly.
#
# Required caller variables per function:
#   resolve_commit_sha: OCP_VERSION, FBC_COMMIT_SHA (in/out), FBC_SHA_PINNED (in/out)
#   verify_fbc_image:   OCP_VERSION, FBC_COMMIT_SHA, FBC_SHA_PINNED
#   wait_for_mcp_rollout: (none - takes argument)
#   ensure_marketplace: (none)
#   wait_for_catalogsource: CATALOG_SOURCE_NAME; CATALOG_IMAGE (optional, for debug)
#   set_proxy: SHARED_DIR
#   gitlab_fetch: (none - takes url, output_file, [max_attempts])
#   log, run: (none)

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

# gitlab.cee regularly returns 503s lasting 30+ seconds; shell-level
# exponential backoff (2+4+8+16+32 = 62s window) is more reliable
# than curl's built-in --retry which doesn't retry on HTTP 5xx.
# Usage: gitlab_fetch <url> <output_file> [max_attempts]
gitlab_fetch() {
    local url="$1" output="$2" max_attempts="${3:-6}"
    local attempt delay
    for attempt in $(seq 1 "$max_attempts"); do
        if curl --insecure -sSf --connect-timeout 10 --max-time 60 \
            "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        delay=$(( 2 ** attempt ))
        log "WARNING: GitLab fetch attempt ${attempt}/${max_attempts} failed (retrying in ${delay}s)..."
        sleep "$delay"
    done
    log "ERROR: Failed to fetch ${url} after ${max_attempts} attempts"
    return 1
}

set_proxy() {
    # shellcheck disable=SC1090
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        log "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

resolve_commit_sha() {
    if [[ -n "$FBC_COMMIT_SHA" ]]; then
        FBC_SHA_PINNED="true"
        log "Using provided FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
        return 0
    fi

    FBC_SHA_PINNED="false"

    if [[ ! "${OCP_VERSION:-}" =~ ^[0-9]{2,4}$ ]]; then
        log "ERROR: OCP_VERSION must be a 2-4 digit string (e.g., '422' for OCP 4.22), got: '${OCP_VERSION:-}'"
        exit 1
    fi

    local image_name="${FBC_IMAGE_PREFIX}-${OCP_VERSION}"
    log "Resolving latest active FBC image for ${image_name} from Quay..."

    local quay_response
    if ! quay_response=$(curl -sSf --retry 3 --retry-delay 2 \
        --connect-timeout 10 --max-time 30 \
        "https://quay.io/api/v1/repository/${QUAY_REPO_PATH}/${image_name}/tag/?limit=50&onlyActiveTags=true" 2>&1); then
        log "ERROR: Quay API request failed for ${image_name}: ${quay_response}"
        exit 1
    fi

    FBC_COMMIT_SHA=$(echo "$quay_response" \
        | jq -r '[.tags[] | select(.name | test("^[0-9a-f]{40}$"))] | sort_by(.start_ts) | reverse | .[0].name // empty')

    if [[ -z "$FBC_COMMIT_SHA" ]]; then
        log "ERROR: No active SHA tag found for ${image_name} on Quay"
        exit 1
    fi

    log "Resolved FBC_COMMIT_SHA: $FBC_COMMIT_SHA (from Quay active tags)"
}

verify_fbc_image() {
    local image_name="${FBC_IMAGE_PREFIX}-${OCP_VERSION}"

    if [[ "${FBC_SHA_PINNED:-}" == "true" ]]; then
        local fbc_image="${FBC_IMAGE_REPO}/${image_name}:${FBC_COMMIT_SHA}"
        log "Verifying pinned FBC image: $fbc_image"
        local manifest_status
        manifest_status=$(curl -sS -o /dev/null -w '%{http_code}' \
            --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
            "https://quay.io/v2/${QUAY_REPO_PATH}/${image_name}/manifests/${FBC_COMMIT_SHA}" \
            -H "Accept: application/vnd.oci.image.index.v1+json" || true)
        if [[ "$manifest_status" != "200" ]]; then
            log "ERROR: Pinned FBC image not found (HTTP ${manifest_status})"
            exit 1
        fi
    fi

    log "Using FBC image: ${FBC_IMAGE_REPO}/${image_name}:${FBC_COMMIT_SHA}"
}

wait_for_mcp_rollout() {
    local mcp_configs_before="$1"

    log "Waiting for MachineConfigPool rollout..."
    local mcp_changed=false
    for i in $(seq 1 30); do
        sleep 10
        local mcp_configs_after
        mcp_configs_after=$(oc get mcp -o jsonpath="$MCP_CONFIG_JSONPATH" 2>/dev/null || true)
        if [[ -n "$mcp_configs_after" && "$mcp_configs_before" != "$mcp_configs_after" ]]; then
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

    local node_name
    node_name=$(oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE_NAME" \
        -o=jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
    if [[ -n "$node_name" ]]; then
        if [[ -n "${CATALOG_IMAGE:-}" ]]; then
            run oc debug "node/$node_name" -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "${CATALOG_IMAGE}" || true
        else
            log "WARNING: CATALOG_IMAGE is unset; skipping node pull diagnostic"
        fi
    fi

    run oc get mcp,node
    return 1
}
MEDIK8S_LIB_EOF

# Single source of truth for the workload image used by all medik8s E2E
# destructive tests (connected, disconnected, upgrade). Change HERE to
# update the image for all environments in one place.
echo "registry.access.redhat.com/ubi9/ubi-minimal:latest" > "${SHARED_DIR}/workload_image"

echo "medik8s-lib.sh written to ${SHARED_DIR}"
