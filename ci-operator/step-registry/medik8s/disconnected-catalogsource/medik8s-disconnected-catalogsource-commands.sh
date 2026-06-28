#!/bin/bash
set -eu -o pipefail
# shellcheck source=/dev/null
source "${SHARED_DIR}/medik8s-lib.sh" || {
    echo "ERROR: medik8s-lib.sh not found in SHARED_DIR." >&2
    echo "Include the medik8s-lib ref before this step." >&2
    exit 1
}

declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare IDMS_NAME="${IDMS_NAME:-medik8s-disconnected}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare GIT_REF="${GIT_REF:-main}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
# shellcheck disable=SC2034 # used by medik8s-lib.sh verify_fbc_image()
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare MEDIK8S_PACKAGES="${MEDIK8S_PACKAGES:-fence-agents-remediation,storage-based-remediation,self-node-remediation,node-healthcheck-operator,node-maintenance-operator,machine-deletion-remediation}"

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

    # --insecure: gitlab.cee uses internal RH CA not trusted by CI pods
    curl --insecure -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
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
        local fbc_parent="${FBC_IMAGE_REPO%/*}"
        local fbc_parent_path="${fbc_parent#quay.io/}"
        echo "  - source: ${fbc_parent}"
        echo "    mirrors:"
        echo "    - ${MIRROR_REGISTRY_HOST}/${fbc_parent_path}"
    } | oc apply -f -

    wait_for_mcp_rollout "$mcp_configs_before"
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
        log "  $(( SECONDS ))s - status: ${status:-pending}"
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
        local catalog_image="${MIRROR_REGISTRY_HOST}/${FBC_IMAGE_REPO#quay.io/}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
        log "Attempting node-side pull diagnostic on ${node_name}..."
        run oc debug "node/$node_name" -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "${catalog_image}" || true
    fi

    run oc get mcp,node
    return 1
}

main() {
    log "=== medik8s Disconnected CatalogSource Setup ==="
    trap 'collect_artifacts' EXIT
    set_proxy
    run oc whoami
    run oc version -o yaml

    if [[ ! "$OCP_VERSION" =~ ^[0-9]{2,4}$ ]]; then
        log "ERROR: OCP_VERSION must be a 2-4 digit string (e.g., '422' for OCP 4.22)"
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

    echo "${FBC_COMMIT_SHA}" > "${SHARED_DIR}/rhwa_fbc_commit_sha"
    echo "${CATALOG_SOURCE_NAME}" > "${SHARED_DIR}/catsrc_name"
    log "=== Done. Disconnected CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
}
main
