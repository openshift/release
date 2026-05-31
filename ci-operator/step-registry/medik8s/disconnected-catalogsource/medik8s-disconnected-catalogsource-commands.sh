#!/bin/bash
set -eu -o pipefail

declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_PROJECT_NAME="dragonfly/rhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"
declare FBC_IMAGE_REPO="quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc"
declare FBC_IMAGE_PREFIX="rhwa-fbc"
declare QUAY_REPO_PATH="redhat-user-workloads/rhwa-tenant/rhwa-fbc"
declare GIT_REF="${GIT_REF:-main}"

declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare IDMS_NAME="${IDMS_NAME:-medik8s-disconnected}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare MEDIK8S_PACKAGES="${MEDIK8S_PACKAGES:-fence-agents-remediation,storage-based-remediation,self-node-remediation,node-healthcheck-operator,node-maintenance-operator,machine-deletion-remediation}"

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

check_mirror_registry() {
    if test -s "${SHARED_DIR}/mirror_registry_url"; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        export MIRROR_REGISTRY_HOST
        log "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        log "ERROR: No mirror registry URL found at \${SHARED_DIR}/mirror_registry_url."
        log "This step requires a disconnected cluster with a mirror registry."
        exit 1
    fi
}

configure_host_pull_secret() {
    log "Configuring pull secrets for mirror registry..."

    local redhat_registry_path="/var/run/vault/mirror-registry/registry_redhat.json"
    local redhat_auth_user redhat_auth_password redhat_registry_auth
    redhat_auth_user=$(jq -r '.user' "$redhat_registry_path")
    redhat_auth_password=$(jq -r '.password' "$redhat_registry_path")
    redhat_registry_auth=$(echo -n "$redhat_auth_user:$redhat_auth_password" | base64 -w 0)

    local mirror_registry_path="/var/run/vault/mirror-registry/registry_creds"
    local mirror_registry_auth
    mirror_registry_auth=$(head -n 1 "$mirror_registry_path" | base64 -w 0)

    oc extract secret/pull-secret -n openshift-config --confirm --to "${TMP_DIR}"
    jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$mirror_registry_auth\"}}" \
        '.auths |= . + $a' "${TMP_DIR}/.dockerconfigjson" > "${XDG_RUNTIME_DIR}/containers/auth.json"

    cp "${XDG_RUNTIME_DIR}/containers/auth.json" "${SHARED_DIR}/containers-auth.json"
    log "Pull secrets configured"
}

install_oc_mirror() {
    log "Installing oc-mirror..."
    curl -sSLf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 \
        -o /tmp/oc-mirror.tar.gz \
        "https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    tar -xzf /tmp/oc-mirror.tar.gz -C /tmp && chmod +x /tmp/oc-mirror
    rm -f /tmp/oc-mirror.tar.gz
    log "oc-mirror installed"
}

create_registries_conf() {
    log "Creating registries.conf from rhwa-fbc IDMS..."

    local idms_url="${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml"
    local idms_file="${TMP_DIR}/idms-source.yaml"
    local registries_conf="${TMP_DIR}/registries.conf"

    curl -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
        "$idms_url" -o "$idms_file" || {
        log "ERROR: Failed to fetch IDMS from $idms_url"
        exit 1
    }

    awk '
        /^[[:space:]]*- mirrors:/ { in_mirrors=1; got_mirror=0 }
        in_mirrors && /^[[:space:]]*- quay\.io/ && !got_mirror {
            gsub(/^[[:space:]]*- /, "", $0); mirror=$0; got_mirror=1
        }
        /^[[:space:]]*source:/ {
            source=$NF; in_mirrors=0
            if (mirror != "" && source != "") {
                printf "[[registry]]\n  location = \"%s\"\n  insecure = true\n  blocked = false\n  mirror-by-digest-only = false\n  [[registry.mirror]]\n      location = \"%s\"\n      insecure = true\n\n", source, mirror
            }
            mirror=""
        }
    ' "$idms_file" > "$registries_conf"

    cp "$registries_conf" "${XDG_RUNTIME_DIR}/containers/registries.conf"
    export CONTAINERS_REGISTRIES_CONF="$registries_conf"
    local entry_count
    entry_count=$(grep -c "^\[\[registry\]\]" "$registries_conf")
    log "registries.conf created with ${entry_count} mirror entries from IDMS"
}

mirror_catalog_and_operators() {
    local fbc_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    log "Mirroring FBC catalog and operator images..."
    log "  FBC image: ${fbc_image}"
    log "  Target: ${MIRROR_REGISTRY_HOST}"

    IFS=',' read -ra RAW_PACKAGES <<< "$MEDIK8S_PACKAGES"
    local packages_yaml=""
    for pkg in "${RAW_PACKAGES[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        packages_yaml+="    - name: ${pkg}"$'\n'
    done

    if [[ -z "$packages_yaml" ]]; then
        log "ERROR: MEDIK8S_PACKAGES did not contain any valid package names"
        exit 1
    fi

    cat > "${TMP_DIR}/imageset-config.yaml" << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${fbc_image}
    packages:
${packages_yaml}
EOF

    log "ImageSetConfiguration:"
    cat "${TMP_DIR}/imageset-config.yaml"

    run env CONTAINERS_REGISTRIES_CONF="${CONTAINERS_REGISTRIES_CONF}" \
        /tmp/oc-mirror --v2 \
        --config="${TMP_DIR}/imageset-config.yaml" \
        --workspace="file://${TMP_DIR}" \
        "docker://${MIRROR_REGISTRY_HOST}" \
        --dest-tls-verify=false \
        --src-tls-verify=false \
        --log-level=info || {
        log "ERROR: oc-mirror failed"
        tar --exclude='./run/containers' --exclude='./.dockerconfigjson' \
            -czC "${TMP_DIR}" -f "${ARTIFACT_DIR}/mirror-debug.tar.gz" . 2>/dev/null || true
        return 1
    }

    tar --exclude='./run/containers' --exclude='./.dockerconfigjson' \
        -czC "${TMP_DIR}" -f "${ARTIFACT_DIR}/mirror-output.tar.gz" . 2>/dev/null || true
    log "Mirroring complete"
}

MCP_CONFIG_JSONPATH='{range .items[*]}{.metadata.name}={.status.configuration.name}{"\n"}{end}'

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

create_idms_disconnected() {
    log "Creating IDMS for disconnected environment..."

    local idms_file="${TMP_DIR}/idms-source.yaml"
    if [[ ! -f "$idms_file" ]]; then
        log "ERROR: IDMS source file not found at ${idms_file}"
        exit 1
    fi

    local mcp_configs_before
    mcp_configs_before=$(oc get mcp -o jsonpath="$MCP_CONFIG_JSONPATH" 2>/dev/null || true)

    {
        echo "apiVersion: config.openshift.io/v1"
        echo "kind: ImageDigestMirrorSet"
        echo "metadata:"
        echo "  name: ${IDMS_NAME}"
        echo "spec:"
        echo "  imageDigestMirrors:"
        awk -v mirror_host="${MIRROR_REGISTRY_HOST}" '
            /^[[:space:]]*- mirrors:/ { in_mirrors=1; got_mirror=0 }
            in_mirrors && /^[[:space:]]*- quay\.io/ && !got_mirror {
                gsub(/^[[:space:]]*- /, "", $0); mirror=$0; got_mirror=1
                gsub(/^quay\.io\//, "", mirror); mirror_path=mirror
            }
            /^[[:space:]]*source:/ {
                source=$NF; in_mirrors=0
                if (mirror_path != "" && source != "") {
                    printf "  - source: %s\n    mirrors:\n    - %s/%s\n", source, mirror_host, mirror_path
                }
                mirror_path=""
            }
        ' "$idms_file"
        echo "  - source: quay.io/redhat-user-workloads/rhwa-tenant"
        echo "    mirrors:"
        echo "    - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/rhwa-tenant"
    } | oc apply -f -

    wait_for_mcp_rollout "$mcp_configs_before"
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
    local original_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    local image_path="${original_image#quay.io/}"
    local catalog_image="${MIRROR_REGISTRY_HOST}/${image_path}"

    log "Creating CatalogSource ${CATALOG_SOURCE_NAME} with mirrored image: ${catalog_image}"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: medik8s Catalog (disconnected)
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  image: "${catalog_image}"
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
    run oc get mcp,node
    return 1
}

main() {
    log "=== medik8s Disconnected CatalogSource Setup ==="
    trap 'collect_artifacts' EXIT
    set_proxy
    run oc whoami
    run oc version -o yaml

    if [[ ! "$OCP_VERSION" =~ ^[0-9]{3,4}$ ]]; then
        log "ERROR: OCP_VERSION must be a 3-4 digit string (e.g., '422' for OCP 4.22)"
        exit 1
    fi

    export TMP_DIR=/tmp/mirror-operators
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    resolve_commit_sha
    verify_fbc_image
    check_mirror_registry
    configure_host_pull_secret
    install_oc_mirror
    create_registries_conf
    mirror_catalog_and_operators
    create_idms_disconnected
    ensure_marketplace
    create_catalogsource
    wait_for_catalogsource

    echo "${FBC_COMMIT_SHA}" > "${SHARED_DIR}/fbc_commit_sha"
    echo "${CATALOG_SOURCE_NAME}" > "${SHARED_DIR}/catsrc_name"
    log "=== Done. Disconnected CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
}
main
