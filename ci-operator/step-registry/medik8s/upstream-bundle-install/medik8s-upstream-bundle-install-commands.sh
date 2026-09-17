#!/bin/bash
set -eu -o pipefail

declare OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-openshift-workload-availability}"
declare OO_INSTALL_MODE="${OO_INSTALL_MODE:-AllNamespaces}"
declare OO_INSTALL_TIMEOUT_MINUTES="${OO_INSTALL_TIMEOUT_MINUTES:-15}"
declare OO_SECURITY_CONTEXT="${OO_SECURITY_CONTEXT:-restricted}"
declare MEDIK8S_BUNDLE_IMAGES="${MEDIK8S_BUNDLE_IMAGES:-}"
declare OO_BUNDLE="${OO_BUNDLE:-}"
declare OO_PACKAGE="${OO_PACKAGE:-}"

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

set_proxy() {
    # shellcheck disable=SC1090
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        log "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

collect_artifacts() {
    log "Collecting debug artifacts..."
    {
        oc get csv -n "$OO_INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/csvs.yaml" || true
        oc get subscription -n "$OO_INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/subscriptions.yaml" || true
        oc get installplan -n "$OO_INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/installplans.yaml" || true
        oc get events -n "$OO_INSTALL_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
            > "${ARTIFACT_DIR}/namespace-events.txt" || true
    } || true
}

ensure_namespace() {
    log "Ensuring namespace ${OO_INSTALL_NAMESPACE}..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  name: ${OO_INSTALL_NAMESPACE}
EOF
}

install_bundle() {
    local pkg="$1"
    local bundle_image="$2"
    log "Installing package ${pkg} from bundle ${bundle_image}"

    local install_mode_arg=""
    if [[ -n "${OO_INSTALL_MODE}" ]]; then
        install_mode_arg="--install-mode=${OO_INSTALL_MODE}"
    fi

    operator-sdk run bundle "${bundle_image}" -n "${OO_INSTALL_NAMESPACE}" \
        --verbose ${install_mode_arg} \
        --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m" \
        --security-context-config="${OO_SECURITY_CONTEXT}"

    wait_for_csv "${pkg}"
}

subscription_csv_for_package() {
    local pkg="$1"
    local sub csv
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        if [[ "$(oc get subscription "$sub" -n "$OO_INSTALL_NAMESPACE" \
            -o jsonpath='{.spec.name}' 2>/dev/null)" == "$pkg" ]]; then
            csv=$(oc get subscription "$sub" -n "$OO_INSTALL_NAMESPACE" \
                -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
            if [[ -n "$csv" ]]; then
                echo "$csv"
                return 0
            fi
        fi
    done < <(oc get subscription -n "$OO_INSTALL_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    return 1
}

wait_for_csv() {
    local pkg="$1"
    # operator-sdk run bundle names subscriptions e.g. storage-based-remediation-v0-0-1-sub,
    # not the OLM package name (medik8s-operator-subscribe uses metadata.name == pkg).
    log "Waiting for CSV for OLM package ${pkg}..."

    local csv=""
    for i in $(seq 1 60); do
        csv=$(subscription_csv_for_package "$pkg" || true)
        if [[ -n "$csv" ]]; then
            log "Found CSV: $csv"
            break
        fi
        log "  attempt ${i}/60 — installedCSV not set yet, waiting 10s..."
        sleep 10
    done

    if [[ -z "$csv" ]]; then
        log "ERROR: No CSV installed for package ${pkg} after 10m"
        oc get subscription -n "$OO_INSTALL_NAMESPACE" -o yaml || true
        return 1
    fi

    log "Waiting for CSV ${csv} to reach Succeeded phase..."
    oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv}" \
        -n "$OO_INSTALL_NAMESPACE" --timeout=15m
}

main() {
    log "=== medik8s upstream bundle install (quay.io/medik8s) ==="
    trap 'collect_artifacts' EXIT
    set_proxy

    if ! command -v operator-sdk &>/dev/null; then
        log "ERROR: operator-sdk not found in PATH"
        exit 1
    fi

    ensure_namespace

    local entries=()
    if [[ -n "$MEDIK8S_BUNDLE_IMAGES" ]]; then
        # Format: pkg=image,pkg2=image2
        local IFS=','
        read -ra entries <<< "$MEDIK8S_BUNDLE_IMAGES"
    elif [[ -n "$OO_BUNDLE" ]]; then
        if [[ -z "$OO_PACKAGE" ]]; then
            log "ERROR: OO_PACKAGE is required when using OO_BUNDLE (OLM package name, e.g. fence-agents-remediation)"
            exit 1
        fi
        entries=("${OO_PACKAGE}=${OO_BUNDLE}")
    else
        log "ERROR: set MEDIK8S_BUNDLE_IMAGES or OO_PACKAGE + OO_BUNDLE"
        exit 1
    fi

    local entry pkg bundle_image
    for entry in "${entries[@]}"; do
        pkg="${entry%%=*}"
        bundle_image="${entry#*=}"
        if [[ -z "$pkg" || -z "$bundle_image" || "$pkg" == "$bundle_image" ]]; then
            log "ERROR: invalid bundle entry '${entry}' (expected package=image)"
            exit 1
        fi
        install_bundle "$pkg" "$bundle_image"
    done

    log "=== Done ==="
}

main "$@"
