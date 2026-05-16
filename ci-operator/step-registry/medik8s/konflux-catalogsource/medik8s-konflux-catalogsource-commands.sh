#!/bin/bash
set -eu -o pipefail

declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_PROJECT_NAME="dragonfly/rhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"
declare GIT_REF="${GIT_REF:-main}"
declare FBC_IMAGE_REPO="quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc"
declare FBC_IMAGE_PREFIX="rhwa-fbc"

declare CATALOG_MODE="${CATALOG_MODE:-konflux}"
declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-konflux-catalog}"
declare CATALOG_IMAGE=""
declare IDMS_NAME="${IDMS_NAME:-medik8s-konflux}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare CATALOG_IMAGE_REF="${CATALOG_IMAGE_REF:-}"

run() {
    echo "running: $*"
    "$@"
}

set_proxy() {
    [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
        echo "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    }
    return 0
}

resolve_commit_sha() {
    if [[ -n "$FBC_COMMIT_SHA" ]]; then
        echo "Using provided FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
        return 0
    fi

    echo "Resolving latest commit from ${GITLAB_PROJECT_NAME} ${GIT_REF} branch..."
    FBC_COMMIT_SHA=$(curl -sSf --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 30 \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/repository/commits/${GIT_REF}" | jq -r .id) || true

    if [[ -z "$FBC_COMMIT_SHA" || "$FBC_COMMIT_SHA" == "null" ]]; then
        echo "ERROR: Failed to resolve rhwa-fbc commit SHA from GitLab API"
        exit 1
    fi

    echo "Resolved FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
}

verify_fbc_image() {
    local fbc_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    echo "Verifying FBC image exists: $fbc_image"

    if ! skopeo inspect "docker://${fbc_image}" > /dev/null 2>&1; then
        if [[ "$FBC_SHA_PINNED" == "true" ]]; then
            echo "ERROR: Pinned FBC image not found: ${fbc_image}"
            echo "The explicitly provided FBC_COMMIT_SHA does not have a corresponding image on Quay"
            exit 1
        fi

        echo "WARNING: FBC image not found for commit ${FBC_COMMIT_SHA}"
        echo "Falling back to listing available tags..."

        local fallback_tag
        fallback_tag=$(skopeo list-tags "docker://${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}" 2>/dev/null \
            | jq -r '.Tags[]?' \
            | grep -E '^[0-9a-f]{40}$' \
            | tail -1) || true

        if [[ -n "$fallback_tag" ]]; then
            echo "Using fallback tag (arbitrary valid commit): $fallback_tag"
            FBC_COMMIT_SHA="$fallback_tag"
        else
            echo "ERROR: No valid FBC image tags found"
            exit 1
        fi
    fi

    echo "FBC image verified: ${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
}

apply_idms() {
    echo "Fetching IDMS from rhwa-fbc commit ${FBC_COMMIT_SHA}..."
    local idms_url="${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml"
    local idms_file="/tmp/medik8s-idms.yaml"

    curl -sSf --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
        "$idms_url" -o "$idms_file" || {
        echo "ERROR: Failed to fetch IDMS from $idms_url"
        exit 1
    }

    sed -i "s/name: rhwa-fbc-fips-image-mirror-set/name: ${IDMS_NAME}/" "$idms_file"

    echo "Applying IDMS..."
    oc apply -f "$idms_file" || {
        echo "ERROR: Failed to apply IDMS"
        exit 1
    }

    echo "IDMS ${IDMS_NAME} applied. Waiting for MCO to process the change..."
    sleep 15
    echo "Waiting for MachineConfigPools to complete update..."
    oc wait mcp --all --for=condition=Updated --timeout=300s || {
        echo "WARNING: MCP not fully updated after 300s, proceeding anyway"
        run oc get mcp
    }
}

ensure_marketplace() {
    echo "Ensuring openshift-marketplace namespace and labels..."
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
    echo "Creating CatalogSource ${CATALOG_SOURCE_NAME} with image: ${CATALOG_IMAGE}"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: medik8s Konflux Catalog
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  image: ${CATALOG_IMAGE}
  publisher: medik8s QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
}

wait_for_catalogsource() {
    echo "Waiting for CatalogSource ${CATALOG_SOURCE_NAME} to be READY..."
    local -i counter=0
    local status=""

    while [[ $counter -lt 600 ]]; do
        counter=$((counter + 20))
        sleep 20
        status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" \
            -o=jsonpath="{.status.connectionState.lastObservedState}" 2>/dev/null || true)
        echo "  ${counter}s - status: ${status:-pending}"
        [[ "$status" == "READY" ]] && {
            echo "CatalogSource ${CATALOG_SOURCE_NAME} is READY"
            return 0
        }
    done

    echo "ERROR: CatalogSource not READY after 600s"
    echo "--- Debug info ---"
    run oc get pods -o wide -n openshift-marketplace
    run oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" -o yaml
    run oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE_NAME" -o yaml

    local node_name
    node_name=$(oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE_NAME" \
        -o=jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
    if [[ -n "$node_name" ]]; then
        run oc debug "node/$node_name" -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "${CATALOG_IMAGE}"
    fi

    run oc get mcp,node
    return 1
}

main() {
    echo "=== medik8s CatalogSource Setup (mode: ${CATALOG_MODE}) ==="
    set_proxy
    run oc whoami
    run oc version -o yaml

    if [[ "$CATALOG_MODE" == "direct" ]]; then
        if [[ -z "$CATALOG_IMAGE_REF" ]]; then
            echo "ERROR: CATALOG_IMAGE_REF is required when CATALOG_MODE=direct"
            echo "Example: registry-proxy.engineering.redhat.com/rh-osbs/iib:1132469 or registry.redhat.io/redhat/redhat-operator-index:v4.22"
            exit 1
        fi
        CATALOG_IMAGE="$CATALOG_IMAGE_REF"
    else
        if [[ -z "$OCP_VERSION" ]]; then
            echo "ERROR: OCP_VERSION env var is required (e.g., '422')"
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

    if [[ "$CATALOG_MODE" != "direct" ]]; then
        echo "${FBC_COMMIT_SHA}" > "${SHARED_DIR}/rhwa_fbc_commit_sha"
        echo "=== Done. Commit SHA exported to \${SHARED_DIR}/rhwa_fbc_commit_sha ==="
    else
        echo "=== Done. CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
    fi
}
main
