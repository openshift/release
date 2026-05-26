#!/bin/bash
set -eu -o pipefail

declare GITLAB_PROJECT="dragonfly%2Frhwa-fbc"
declare GITLAB_PROJECT_NAME="dragonfly/rhwa-fbc"
declare GITLAB_API="https://gitlab.cee.redhat.com/api/v4"
declare GITLAB_RAW="https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/raw"
declare FBC_IMAGE_REPO="quay.io/redhat-user-workloads/rhwa-tenant/rhwa-fbc"
declare FBC_IMAGE_PREFIX="rhwa-fbc"
declare GIT_REF="${GIT_REF:-main}"

declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare IDMS_NAME="${IDMS_NAME:-medik8s-disconnected}"
declare OCP_VERSION="${OCP_VERSION:-}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
declare MEDIK8S_PACKAGES="${MEDIK8S_PACKAGES:-fence-agents-remediation,storage-based-remediation,self-node-remediation,node-healthcheck-operator,node-maintenance-operator,machine-deletion-remediation}"

run() {
    echo "running: $*"
    "$@"
}

timestamp() {
    date -u --rfc-3339=seconds
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

    local encoded_ref
    encoded_ref=$(jq -rn --arg ref "$GIT_REF" '$ref | @uri') || encoded_ref="$GIT_REF"

    echo "Resolving latest commit from ${GITLAB_PROJECT_NAME} ${GIT_REF} ref..."
    FBC_COMMIT_SHA=$(curl -sSf --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 30 \
        "${GITLAB_API}/projects/${GITLAB_PROJECT}/repository/commits/${encoded_ref}" | jq -r .id) || true

    if [[ -z "$FBC_COMMIT_SHA" || "$FBC_COMMIT_SHA" == "null" ]]; then
        echo "ERROR: Failed to resolve rhwa-fbc commit SHA from GitLab API"
        exit 1
    fi

    echo "Resolved FBC_COMMIT_SHA: $FBC_COMMIT_SHA"
}

check_mirror_registry() {
    if test -s "${SHARED_DIR}/mirror_registry_url"; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        export MIRROR_REGISTRY_HOST
        echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        echo "ERROR: No mirror registry URL found at \${SHARED_DIR}/mirror_registry_url."
        echo "This step requires a disconnected cluster with a mirror registry."
        exit 1
    fi
}

configure_host_pull_secret() {
    echo "[$(timestamp)] Configuring pull secrets for mirror registry..."

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
    echo "[$(timestamp)] Pull secrets configured"
}

install_oc_mirror() {
    echo "[$(timestamp)] Installing oc-mirror..."
    curl -sSLf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 \
        -o /tmp/oc-mirror.tar.gz \
        "https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    tar -xzf /tmp/oc-mirror.tar.gz -C /tmp && chmod +x /tmp/oc-mirror
    rm -f /tmp/oc-mirror.tar.gz
    echo "[$(timestamp)] oc-mirror installed"
}

create_registries_conf() {
    echo "[$(timestamp)] Creating registries.conf from rhwa-fbc IDMS..."

    local idms_url="${GITLAB_RAW}/${FBC_COMMIT_SHA}/.tekton/images-mirror-set.yaml"
    local idms_file="${TMP_DIR}/idms-source.yaml"
    local registries_conf="${TMP_DIR}/registries.conf"

    curl -sSf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
        "$idms_url" -o "$idms_file" || {
        echo "ERROR: Failed to fetch IDMS from $idms_url"
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
    echo "[$(timestamp)] registries.conf created with ${entry_count} mirror entries from IDMS"
}

mirror_catalog_and_operators() {
    local fbc_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    echo "[$(timestamp)] Mirroring FBC catalog and operator images..."
    echo "  FBC image: ${fbc_image}"
    echo "  Target: ${MIRROR_REGISTRY_HOST}"

    IFS=',' read -ra PACKAGES <<< "$MEDIK8S_PACKAGES"
    local packages_yaml=""
    for pkg in "${PACKAGES[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        packages_yaml+="    - name: ${pkg}"$'\n'
    done

    cat > "${TMP_DIR}/imageset-config.yaml" << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${fbc_image}
    packages:
${packages_yaml}
EOF

    echo "[$(timestamp)] ImageSetConfiguration:"
    cat "${TMP_DIR}/imageset-config.yaml"

    run env CONTAINERS_REGISTRIES_CONF="${CONTAINERS_REGISTRIES_CONF}" \
        /tmp/oc-mirror --v2 \
        --config="${TMP_DIR}/imageset-config.yaml" \
        --workspace="file://${TMP_DIR}" \
        "docker://${MIRROR_REGISTRY_HOST}" \
        --dest-tls-verify=false \
        --src-tls-verify=false \
        --log-level=info || {
        echo "ERROR: oc-mirror failed"
        tar --exclude='./run/containers' --exclude='./.dockerconfigjson' \
            -czC "${TMP_DIR}" -f "${ARTIFACT_DIR}/mirror-debug.tar.gz" . 2>/dev/null || true
        return 1
    }

    tar --exclude='./run/containers' --exclude='./.dockerconfigjson' \
        -czC "${TMP_DIR}" -f "${ARTIFACT_DIR}/mirror-output.tar.gz" . 2>/dev/null || true
    echo "[$(timestamp)] Mirroring complete"
}

create_idms_disconnected() {
    echo "[$(timestamp)] Creating IDMS for disconnected environment..."

    local idms_file="${TMP_DIR}/idms-source.yaml"
    if [[ ! -f "$idms_file" ]]; then
        echo "ERROR: IDMS source file not found at ${idms_file}"
        exit 1
    fi

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

    echo "[$(timestamp)] Waiting for MachineConfigPool rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || {
        echo "WARNING: MCP not fully updated after 20m, proceeding anyway"
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
    local original_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    local image_path
    image_path=$(echo "$original_image" | sed 's|^quay.io/||')
    local catalog_image="${MIRROR_REGISTRY_HOST}/${image_path}"

    echo "Creating CatalogSource ${CATALOG_SOURCE_NAME} with mirrored image: ${catalog_image}"

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
  image: ${catalog_image}
  publisher: medik8s QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
}

wait_for_catalogsource() {
    echo "Waiting for CatalogSource ${CATALOG_SOURCE_NAME} to be READY..."
    local -i deadline=$(( SECONDS + 600 ))
    local status=""

    while (( SECONDS < deadline )); do
        sleep 20
        status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE_NAME" \
            -o=jsonpath="{.status.connectionState.lastObservedState}" 2>/dev/null || true)
        echo "  $(( SECONDS ))s - status: ${status:-pending}"
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
    echo "--- Marketplace events ---"
    oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    run oc get mcp,node
    return 1
}

main() {
    echo "=== medik8s Disconnected CatalogSource Setup ==="
    set_proxy
    run oc whoami
    run oc version -o yaml

    if [[ ! "$OCP_VERSION" =~ ^[0-9]{3,4}$ ]]; then
        echo "ERROR: OCP_VERSION must be a 3-4 digit string (e.g., '422' for OCP 4.22)"
        exit 1
    fi

    export TMP_DIR=/tmp/mirror-operators
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    resolve_commit_sha
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
    echo "=== Done. Disconnected CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
}
main
