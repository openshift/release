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
declare OCP_VERSION="${FBC_OCP_VERSION:-${OCP_VERSION:-}}"
declare GIT_REF="${GIT_REF:-main}"
declare FBC_COMMIT_SHA="${FBC_COMMIT_SHA:-}"
# shellcheck disable=SC2034 # used by medik8s-lib.sh verify_fbc_image()
declare FBC_SHA_PINNED="${FBC_COMMIT_SHA:+true}"
declare MEDIK8S_PACKAGES="${MEDIK8S_PACKAGES:-fence-agents-remediation,storage-based-remediation,self-node-remediation,node-healthcheck-operator,node-maintenance-operator,machine-deletion-remediation}"

collect_artifacts() {
    log "Collecting debug artifacts..."
    for mcp in master worker; do
        oc patch mcp "${mcp}" --type=merge --patch '{"spec":{"paused":false}}' 2>/dev/null || true
    done
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

    gitlab_fetch "$idms_url" "$idms_file" || exit 1

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

    # Two-pass disk-based mirroring so oc-mirror rewrites catalog references.
    # mirrorToMirror (single-pass) leaves bundle image refs as the original
    # registry.redhat.io URLs inside the FBC; OLM's bundle unpack Job then
    # tries to pull from the original source (unreachable in disconnected mode)
    # and hangs until the 10-min activeDeadlineSeconds.
    # mirrorToDisk → diskToMirror rewrites all refs to mirror URLs, so OLM
    # reads the mirror URL directly from the catalog — no IDMS redirect needed.

    log "Pass 1: mirror catalog and operator images to local disk..."
    run env CONTAINERS_REGISTRIES_CONF="${CONTAINERS_REGISTRIES_CONF}" \
        /tmp/oc-mirror --v2 \
        --config="${TMP_DIR}/imageset-config.yaml" \
        "file://${TMP_DIR}" \
        --src-tls-verify=false \
        --log-level=info || {
        log "ERROR: oc-mirror pass 1 (mirrorToDisk) failed"
        tar --exclude='./run/containers' --exclude='./.dockerconfigjson' \
            -czC "${TMP_DIR}" -f "${ARTIFACT_DIR}/mirror-debug.tar.gz" . 2>/dev/null || true
        return 1
    }

    log "Pass 2: push images from disk to mirror registry (rewrites catalog refs to mirror URLs)..."
    run /tmp/oc-mirror --v2 \
        --config="${TMP_DIR}/imageset-config.yaml" \
        --from "file://${TMP_DIR}" \
        "docker://${MIRROR_REGISTRY_HOST}" \
        --dest-tls-verify=false \
        --log-level=info || {
        log "ERROR: oc-mirror pass 2 (diskToMirror) failed"
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

    # Pause MCPs before applying any mirror resources so all changes are batched
    # into a single MCO rollout (pattern from cnv/deploy-cnv).
    log "Pausing MCPs to batch mirror config changes into a single rollout..."
    for mcp in master worker; do
        oc patch mcp "${mcp}" --type=merge --patch '{"spec":{"paused":true}}' 2>/dev/null || true
    done

    local mcp_configs_before
    mcp_configs_before=$(oc get mcp -o jsonpath="$MCP_CONFIG_JSONPATH" 2>/dev/null || true)

    # Apply ONLY the oc-mirror generated IDMS. It has the correct source→mirror
    # mappings matching exactly where oc-mirror pushed the images:
    #   registry.redhat.io/workload-availability → ec2-xxx:5000/workload-availability
    #
    # Do NOT apply the GitLab images-mirror-set.yaml IDMS. That file maps bundle
    # images to their Konflux build locations (quay.io/redhat-user-workloads/rhwa-
    # tenant/storage-based-remediation/sbr-bundle-0-3), which is a different path
    # than where oc-mirror puts them. Applying it creates a more-specific IDMS
    # entry that overrides the oc-mirror mapping with a wrong mirror path →
    # "manifest unknown" when the bundle unpack Job tries to pull.
    local ocmirror_idms="${TMP_DIR}/working-dir/cluster-resources/idms-oc-mirror.yaml"
    if [[ -f "$ocmirror_idms" ]]; then
        log "Applying oc-mirror generated IDMS (exact source→mirror mappings)..."
        oc apply -f "$ocmirror_idms"
    else
        log "ERROR: oc-mirror IDMS not found at ${ocmirror_idms}"
        exit 1
    fi

    # Resume MCPs — single consolidated rollout with only the correct IDMS.
    log "Resuming MCPs to trigger MCO rollout..."
    for mcp in master worker; do
        oc patch mcp "${mcp}" --type=merge --patch '{"spec":{"paused":false}}' 2>/dev/null || true
    done

    wait_for_mcp_rollout "$mcp_configs_before"
}

create_catalogsource() {
    local original_image="${FBC_IMAGE_REPO}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    local image_path="${original_image#quay.io/}"
    local catalog_image="${MIRROR_REGISTRY_HOST}/${image_path}"

    # Create a pull secret in openshift-marketplace so OLM's bundle unpack Job
    # has explicit credentials for the mirror registry. Without this, the Job
    # relies solely on the cluster's global pull-secret for IDMS-redirected pulls,
    # which consistently fails for the registry.redhat.io → mirror redirect path.
    local mirror_secret_name="medik8s-mirror-pull-secret"
    local mirror_registry_auth
    mirror_registry_auth=$(head -n 1 /var/run/vault/mirror-registry/registry_creds | base64 -w 0)
    log "Creating mirror pull secret ${mirror_secret_name} in openshift-marketplace..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${mirror_secret_name}
  namespace: openshift-marketplace
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(echo -n "{\"auths\":{\"${MIRROR_REGISTRY_HOST}\":{\"auth\":\"${mirror_registry_auth}\"}}}" | base64 -w 0)
EOF

    log "Creating CatalogSource ${CATALOG_SOURCE_NAME} with mirrored image: ${catalog_image}"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: medik8s Catalog (disconnected)
  image: "${catalog_image}"
  publisher: medik8s QE
  secrets:
  - ${mirror_secret_name}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
}

main() {
    log "=== medik8s Disconnected CatalogSource Setup ==="
    trap 'collect_artifacts' EXIT

    if [[ ! "$OCP_VERSION" =~ ^[0-9]{2,4}$ ]]; then
        log "ERROR: OCP_VERSION must be a 2-4 digit string (e.g., '422' for OCP 4.22)"
        exit 1
    fi

    export TMP_DIR=/tmp/mirror-operators
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    # Resolve GitLab refs and fetch IDMS BEFORE setting the proxy.
    # set_proxy routes all traffic through the bastion Squid proxy
    # (port 3128) in disconnected envs — that proxy cannot reliably
    # reach gitlab.cee.redhat.com, causing 503 / timeout failures.
    resolve_commit_sha
    verify_fbc_image
    create_registries_conf

    set_proxy
    run oc whoami
    run oc version -o yaml

    check_mirror_registry
    configure_host_pull_secret
    install_oc_mirror
    mirror_catalog_and_operators
    create_idms_disconnected
    ensure_marketplace
    create_catalogsource
    # shellcheck disable=SC2034 # used by medik8s-lib.sh wait_for_catalogsource()
    CATALOG_IMAGE="${MIRROR_REGISTRY_HOST}/${FBC_IMAGE_REPO#quay.io/}/${FBC_IMAGE_PREFIX}-${OCP_VERSION}:${FBC_COMMIT_SHA}"
    wait_for_catalogsource

    echo "${FBC_COMMIT_SHA}" > "${SHARED_DIR}/rhwa_fbc_commit_sha"
    echo "${CATALOG_SOURCE_NAME}" > "${SHARED_DIR}/catsrc_name"
    log "=== Done. Disconnected CatalogSource ${CATALOG_SOURCE_NAME} is READY ==="
}
main
