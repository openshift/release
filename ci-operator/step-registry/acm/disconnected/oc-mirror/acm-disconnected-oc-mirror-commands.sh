#!/bin/bash
set -euo pipefail

declare ACM_IIB_IMAGE="${ACM_IIB_IMAGE:-}"
declare ACM_VERSION="${ACM_VERSION:-}"
declare MCE_IIB_IMAGE="${MCE_IIB_IMAGE:-}"
declare MCE_VERSION="${MCE_VERSION:-}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

collect_artifacts() {
    log "Collecting debug artifacts..."
    {
        cp "${TMP_DIR}/isc-acm-mce.yaml" "${ARTIFACT_DIR}/isc-acm-mce.yaml" 2>/dev/null || true
        cp "${TMP_DIR}/catalogsource-acm.yaml" "${ARTIFACT_DIR}/catalogsource-acm.yaml" 2>/dev/null || true
        cp "${TMP_DIR}/catalogsource-mce.yaml" "${ARTIFACT_DIR}/catalogsource-mce.yaml" 2>/dev/null || true
        cp "${TMP_DIR}/idms-acm-mce.yaml" "${ARTIFACT_DIR}/idms-acm-mce.yaml" 2>/dev/null || true
        oc -n openshift-marketplace get catalogsource -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/catalogsources.yaml"
        oc -n openshift-marketplace get pods -o wide 2>/dev/null \
            > "${ARTIFACT_DIR}/marketplace-pods.txt"
        oc get events -n openshift-marketplace --sort-by='.lastTimestamp' 2>/dev/null \
            > "${ARTIFACT_DIR}/marketplace-events.txt"
        oc get imagedigestmirrorset -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/imagedigestmirrorsets.yaml"
    } || true
    if [[ -f "${TMP_DIR}/acm_mce_mirror.log" ]]; then
        cp "${TMP_DIR}/acm_mce_mirror.log" "${ARTIFACT_DIR}/acm_mce_mirror.log"
    fi
    if [[ -f "${TMP_DIR}/acm_mce_mirror_dry_run.log" ]]; then
        cp "${TMP_DIR}/acm_mce_mirror_dry_run.log" "${ARTIFACT_DIR}/acm_mce_mirror_dry_run.log"
    fi
}

check_mirror_registry() {
    if [[ -s "${SHARED_DIR}/mirror_registry_url" ]]; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        export MIRROR_REGISTRY_HOST
        log "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        log "ERROR: No mirror registry URL found at \${SHARED_DIR}/mirror_registry_url."
        exit 1
    fi
}

configure_pull_secrets() {
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
    local cgw_url="https://mirror.openshift.com/pub/cgw"
    local arch
    arch=$(uname -m)
    case ${arch} in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    curl -sSLf --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 \
        -o /tmp/oc-mirror.tar.gz \
        "${cgw_url}/oc-mirror/latest/oc-mirror-rhel9-linux-${arch}.tar.gz"
    tar -xzf /tmp/oc-mirror.tar.gz -C /tmp && chmod +x /tmp/oc-mirror
    rm -f /tmp/oc-mirror.tar.gz
    log "oc-mirror installed"
}

create_imageset_config() {
    log "Creating ImageSetConfiguration for ACM and MCE IIB images..."
    log "  ACM IIB: ${ACM_IIB_IMAGE}"
    log "  MCE IIB: ${MCE_IIB_IMAGE}"

    cat > "${TMP_DIR}/isc-acm-mce.yaml" <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${ACM_IIB_IMAGE}
    packages:
    - name: advanced-cluster-management
  - catalog: ${MCE_IIB_IMAGE}
    packages:
    - name: multicluster-engine
EOF

    log "ImageSetConfiguration:"
    cat "${TMP_DIR}/isc-acm-mce.yaml"
}

mirror_operators() {
    log "Mirroring ACM/MCE operators to ${MIRROR_REGISTRY_HOST}..."

    log "Mirroring directly from source to ${MIRROR_REGISTRY_HOST}..."
    /tmp/oc-mirror --v2 \
        --config="${TMP_DIR}/isc-acm-mce.yaml" \
        "docker://${MIRROR_REGISTRY_HOST}" \
        --src-tls-verify=false \
        --dest-tls-verify=false \
        --log-level=info 2>&1 | tee "${TMP_DIR}/acm_mce_mirror.log" || {
        log "ERROR: oc-mirror failed"
        return 1
    }

    log "Mirroring complete"
}

apply_idms() {
    log "Applying IDMS from oc-mirror output..."

    local ocmirror_idms="${TMP_DIR}/working-dir/cluster-resources/idms-oc-mirror.yaml"
    if [[ -f "$ocmirror_idms" ]]; then
        cp "$ocmirror_idms" "${TMP_DIR}/idms-acm-mce.yaml"
        oc apply -f "$ocmirror_idms"
        log "IDMS applied"
    else
        log "WARNING: oc-mirror IDMS not found at ${ocmirror_idms}"
    fi

    local ocmirror_itms="${TMP_DIR}/working-dir/cluster-resources/itms-oc-mirror.yaml"
    if [[ -f "$ocmirror_itms" ]]; then
        oc apply -f "$ocmirror_itms"
        log "ITMS applied"
    else
        log "WARNING: oc-mirror ITMS not found at ${ocmirror_itms}"
    fi

    log "Waiting for MCP rollout after mirror set changes..."
    oc wait mcp master worker --for condition=Updated --timeout=15m || true
}

create_mirror_pull_secret() {
    local mirror_registry_auth
    mirror_registry_auth=$(head -n 1 /var/run/vault/mirror-registry/registry_creds | base64 -w 0)

    local secret_name="acm-mce-mirror-pull-secret"
    log "Creating mirror pull secret ${secret_name} in openshift-marketplace..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: openshift-marketplace
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(echo -n "{\"auths\":{\"${MIRROR_REGISTRY_HOST}\":{\"auth\":\"${mirror_registry_auth}\"}}}" | base64 -w 0)
EOF
    echo "$secret_name"
}

create_catalogsources() {
    local pull_secret_name
    pull_secret_name=$(create_mirror_pull_secret)

    local acm_mirrored_index="${MIRROR_REGISTRY_HOST}/${ACM_IIB_IMAGE#*/}"
    log "Creating CatalogSource for ACM with image: ${acm_mirrored_index}"
    cat > "${TMP_DIR}/catalogsource-acm.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: acm-catalog-${ACM_VERSION}
  namespace: openshift-marketplace
spec:
  displayName: ACM ${ACM_VERSION} Catalog (disconnected)
  image: "${acm_mirrored_index}"
  publisher: ACM QE
  secrets:
  - ${pull_secret_name}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    oc apply -f "${TMP_DIR}/catalogsource-acm.yaml"

    local mce_mirrored_index="${MIRROR_REGISTRY_HOST}/${MCE_IIB_IMAGE#*/}"
    log "Creating CatalogSource for MCE with image: ${mce_mirrored_index}"
    cat > "${TMP_DIR}/catalogsource-mce.yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mce-catalog-${MCE_VERSION}
  namespace: openshift-marketplace
spec:
  displayName: MCE ${MCE_VERSION} Catalog (disconnected)
  image: "${mce_mirrored_index}"
  publisher: ACM QE
  secrets:
  - ${pull_secret_name}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    oc apply -f "${TMP_DIR}/catalogsource-mce.yaml"

    log "Waiting for CatalogSources to become READY..."
    local retries=30
    while ((retries > 0)); do
        local acm_state mce_state
        acm_state=$(oc get catalogsource "acm-catalog-${ACM_VERSION}" -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
        mce_state=$(oc get catalogsource "mce-catalog-${MCE_VERSION}" -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
        if [[ "$acm_state" == "READY" && "$mce_state" == "READY" ]]; then
            log "Both CatalogSources are READY"
            return 0
        fi
        log "ACM catalog: ${acm_state:-pending}, MCE catalog: ${mce_state:-pending} (retries left: ${retries})"
        sleep 20
        ((retries--))
    done
    log "ERROR: CatalogSources did not reach READY state"
    return 1
}

main() {
    log "=== ACM/MCE Disconnected oc-mirror Setup ==="
    trap 'collect_artifacts' EXIT

    if [[ -z "$ACM_IIB_IMAGE" ]]; then
        log "ERROR: ACM_IIB_IMAGE must be set"
        exit 1
    fi
    if [[ -z "$MCE_IIB_IMAGE" ]]; then
        log "ERROR: MCE_IIB_IMAGE must be set"
        exit 1
    fi
    if [[ -z "$ACM_VERSION" ]]; then
        log "ERROR: ACM_VERSION must be set"
        exit 1
    fi
    if [[ -z "$MCE_VERSION" ]]; then
        log "ERROR: MCE_VERSION must be set"
        exit 1
    fi

    export TMP_DIR=/tmp/mirror-acm-operators
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
        source "${SHARED_DIR}/proxy-conf.sh"
    fi

    check_mirror_registry
    configure_pull_secrets
    install_oc_mirror
    create_imageset_config
    mirror_operators
    apply_idms
    create_catalogsources

    echo "acm-catalog-${ACM_VERSION}" > "${SHARED_DIR}/acm_catsrc_name"
    echo "mce-catalog-${MCE_VERSION}" > "${SHARED_DIR}/mce_catsrc_name"
    log "=== Done. ACM and MCE mirrored catalogs are READY ==="
}
main
