#!/bin/bash
set -eu -o pipefail

declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_PROJECT_NAME="dragonfly/rhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"
declare GIT_REF="${GIT_REF:-main}"
declare FBC_IMAGE_REPO="quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc"
declare FBC_IMAGE_PREFIX="rhwa-fbc"
declare QUAY_REPO_PATH="redhat-user-workloads/rhwa-tenant/rhwa-fbc"

declare CATALOG_MODE="${CATALOG_MODE:-konflux}"
declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare CATALOG_IMAGE=""
declare IDMS_NAME="${IDMS_NAME:-medik8s-konflux}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare CATALOG_IMAGE_REF="${CATALOG_IMAGE_REF:-}"

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

run() {
    log "running: $*"
    "$@"
}

collect_artifacts() {
    log "Collecting debug artifacts..."
    {
        oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/catalogsource.yaml"
        oc -n openshift-marketplace get pods -o wide 2>/dev/null \
            > "${ARTIFACT_DIR}/marketplace-pods.txt"
        oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE_NAME" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/catalog-pod.yaml"
        oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>/dev/null \
            > "${ARTIFACT_DIR}/marketplace-events.txt"
        oc get mcp 2>/dev/null \
            > "${ARTIFACT_DIR}/machineconfigpools.txt"
    } || true
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

apply_idms() {
    log "Fetching IDMS from rhwa-fbc commit ${FBC_COMMIT_SHA}..."
    local idms_url="${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml"
    local idms_file
    idms_file=$(mktemp)

    curl -sSf --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
        "$idms_url" -o "$idms_file" || {
        log "ERROR: Failed to fetch IDMS from $idms_url"
        exit 1
    }

    yq-v4 -i ".metadata.name = \"${IDMS_NAME}\"" "$idms_file"

    log "Applying IDMS..."
    oc apply -f "$idms_file" || {
        log "ERROR: Failed to apply IDMS"
        exit 1
    }
    cp "$idms_file" "${ARTIFACT_DIR}/idms.yaml" 2>/dev/null || true

    log "IDMS ${IDMS_NAME} applied. Waiting for MachineConfigPool rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || {
        log "WARNING: MCP not fully updated after 20m, proceeding anyway"
        run oc get mcp
    }
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

create_catalogsource() {
    log "Creating CatalogSource ${CATALOG_SOURCE_NAME} with image: ${CATALOG_IMAGE}"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: medik8s Catalog
  image: "${CATALOG_IMAGE}"
  publisher: medik8s QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
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
        run oc debug "node/$node_name" -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "${CATALOG_IMAGE}" || true
    fi

    run oc get mcp,node
    return 1
}

main() {
    log "=== medik8s CatalogSource Setup (mode: ${CATALOG_MODE}) ==="
    trap 'collect_artifacts' EXIT
    set_proxy
    run oc whoami
    run oc version -o yaml

    if [[ "$CATALOG_MODE" != "konflux" && "$CATALOG_MODE" != "direct" ]]; then
        log "ERROR: Unknown CATALOG_MODE '${CATALOG_MODE}'. Must be 'konflux' or 'direct'"
        exit 1
    fi

    if [[ "$CATALOG_MODE" == "direct" ]]; then
        if [[ -z "$CATALOG_IMAGE_REF" ]]; then
            log "ERROR: CATALOG_IMAGE_REF is required when CATALOG_MODE=direct"
            log "Use cases: GA IIB validation, released operator testing, custom catalog images"
            log "Examples:"
            log "  GA IIB:           registry-proxy.engineering.redhat.com/rh-osbs/iib:1132469"
            log "  Red Hat catalog:  registry.redhat.io/redhat/redhat-operator-index:v4.22"
            exit 1
        fi
        CATALOG_IMAGE="$CATALOG_IMAGE_REF"
    else
        if [[ ! "$OCP_VERSION" =~ ^[0-9]{2,4}$ ]]; then
            log "ERROR: OCP_VERSION must be a 2-4 digit string (e.g., '422' for OCP 4.22)"
            exit 1
        fi
        resolve_commit_sha
        verify_fbc_image
        apply_idms
        CATALOG_IMAGE="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    fi

    ensure_marketplace
    create_catalogsource
    wait_for_catalogsource

    echo "${CATALOG_SOURCE_NAME}" > "${SHARED_DIR}/catsrc_name"
    if [[ "$CATALOG_MODE" != "direct" ]]; then
        echo "${FBC_COMMIT_SHA}" > "${SHARED_DIR}/rhwa_fbc_commit_sha"
        log "=== Done. Commit SHA exported to \${SHARED_DIR}/rhwa_fbc_commit_sha ==="
    else
        log "=== Done. CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
    fi
}
main
