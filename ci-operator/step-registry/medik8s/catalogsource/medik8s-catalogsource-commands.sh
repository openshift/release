#!/bin/bash
set -eu -o pipefail
source "${SHARED_DIR}/medik8s-lib.sh"

declare CATALOG_MODE="${CATALOG_MODE:-konflux}"
declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare CATALOG_IMAGE=""
declare IDMS_NAME="${IDMS_NAME:-medik8s-konflux}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare GIT_REF="${GIT_REF:-main}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare CATALOG_IMAGE_REF="${CATALOG_IMAGE_REF:-}"

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

    local mcp_configs_before
    mcp_configs_before=$(oc get mcp -o jsonpath="$MCP_CONFIG_JSONPATH" 2>/dev/null || true)

    log "Applying IDMS..."
    oc apply -f "$idms_file" || {
        log "ERROR: Failed to apply IDMS"
        exit 1
    }
    cp "$idms_file" "${ARTIFACT_DIR}/idms.yaml" 2>/dev/null || true

    wait_for_mcp_rollout "$mcp_configs_before"
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
