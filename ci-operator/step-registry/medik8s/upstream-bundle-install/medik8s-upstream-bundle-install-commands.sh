#!/bin/bash
set -eu -o pipefail

declare OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-openshift-workload-availability}"
declare OO_INSTALL_TIMEOUT_MINUTES="${OO_INSTALL_TIMEOUT_MINUTES:-10}"
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
    # Bare minimum matching historical medik8s bundle-run installs (e.g. FAR):
    # disable SCC label sync and set PSA enforce=privileged so remediation
    # operator pods can run. FAR tests assert enforce=privileged.
    log "Ensuring namespace ${OO_INSTALL_NAMESPACE}..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
  name: ${OO_INSTALL_NAMESPACE}
EOF
}

# Resolves a package name to the Quay main bundle image.
# Most packages use <pkg>-operator-bundle; NHC/NMO already end in -operator
# and publish <pkg>-bundle instead (avoid ...-operator-operator-bundle).
default_bundle_image() {
    local pkg="$1"
    if [[ "$pkg" == *-operator ]]; then
        echo "quay.io/medik8s/${pkg}-bundle:latest"
    else
        echo "quay.io/medik8s/${pkg}-operator-bundle:latest"
    fi
}

resolve_bundle_entry() {
    local entry="$1"
    local pkg image
    if [[ "$entry" == *"="* ]]; then
        pkg="${entry%%=*}"
        image="${entry#*=}"
    else
        pkg="$entry"
        image=""
    fi
    if [[ -z "$pkg" ]]; then
        log "ERROR: invalid bundle entry '${entry}' (empty package name)"
        return 1
    fi
    if [[ -z "$image" ]]; then
        image="$(default_bundle_image "$pkg")"
    fi
    echo "${pkg}=${image}"
}

install_bundle() {
    local pkg="$1"
    local bundle_image="$2"
    log "Installing package ${pkg} from bundle ${bundle_image}"

    operator-sdk run bundle "${bundle_image}" -n "${OO_INSTALL_NAMESPACE}" \
        --verbose \
        --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m"

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
    local attempts=$((OO_INSTALL_TIMEOUT_MINUTES * 6))
    for i in $(seq 1 "$attempts"); do
        csv=$(subscription_csv_for_package "$pkg" || true)
        if [[ -n "$csv" ]]; then
            log "Found CSV: $csv"
            break
        fi
        log "  attempt ${i}/${attempts} — installedCSV not set yet, waiting 10s..."
        sleep 10
    done

    if [[ -z "$csv" ]]; then
        log "ERROR: No CSV installed for package ${pkg} after ${OO_INSTALL_TIMEOUT_MINUTES}m"
        oc get subscription -n "$OO_INSTALL_NAMESPACE" -o yaml || true
        return 1
    fi

    log "Waiting for CSV ${csv} to reach Succeeded phase..."
    oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv}" \
        -n "$OO_INSTALL_NAMESPACE" --timeout="${OO_INSTALL_TIMEOUT_MINUTES}m"
}

main() {
    log "=== medik8s upstream bundle install (quay.io/medik8s) ==="
    trap 'collect_artifacts' EXIT
    set_proxy

    # Safeguard if the operator-sdk base image ever drops the binary from PATH.
    if ! command -v operator-sdk &>/dev/null; then
        log "ERROR: operator-sdk not found in PATH"
        exit 1
    fi

    ensure_namespace

    local raw_entries=()
    if [[ -n "$MEDIK8S_BUNDLE_IMAGES" ]]; then
        local IFS=','
        read -ra raw_entries <<< "$MEDIK8S_BUNDLE_IMAGES"
    elif [[ -n "$OO_PACKAGE" ]]; then
        if [[ -n "$OO_BUNDLE" ]]; then
            raw_entries=("${OO_PACKAGE}=${OO_BUNDLE}")
        else
            raw_entries=("${OO_PACKAGE}")
        fi
    else
        log "ERROR: set MEDIK8S_BUNDLE_IMAGES or OO_PACKAGE (+ optional OO_BUNDLE)"
        exit 1
    fi

    local entry resolved pkg bundle_image
    for entry in "${raw_entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" ]] && continue
        resolved="$(resolve_bundle_entry "$entry")"
        pkg="${resolved%%=*}"
        bundle_image="${resolved#*=}"
        install_bundle "$pkg" "$bundle_image"
    done

    log "=== Done ==="
}

main "$@"
