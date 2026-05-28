#!/bin/bash
set -eu -o pipefail

declare CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-medik8s-catalog}"
declare OO_CHANNEL="${OO_CHANNEL:-candidate}"
declare INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-openshift-workload-availability}"
declare OPERATORS="${OPERATORS:-}"

# SHARED_DIR is a ci-operator shared workspace for passing artifacts between
# workflow steps. This step reads the following files from it:
#   - proxy-conf.sh : proxy environment settings (written by cluster provisioner)
#   - catsrc_name   : CatalogSource name (written by the medik8s-catalogsource step)

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

collect_artifacts() {
    log "Collecting debug artifacts..."
    {
        oc get csv -n "$INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/csvs.yaml"
        oc get subscription -n "$INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/subscriptions.yaml"
        oc get installplan -n "$INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/installplans.yaml"
        oc get operatorgroup -n "$INSTALL_NAMESPACE" -o yaml 2>/dev/null \
            > "${ARTIFACT_DIR}/operatorgroup.yaml"
        oc get events -n "$INSTALL_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
            > "${ARTIFACT_DIR}/namespace-events.txt"
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

ensure_namespace() {
    log "Ensuring namespace ${INSTALL_NAMESPACE}..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  name: ${INSTALL_NAMESPACE}
EOF
}

ensure_operatorgroup() {
    local existing
    existing=$(oc -n "$INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        local count
        count=$(echo "$existing" | wc -w)
        if [[ $count -gt 1 ]]; then
            log "ERROR: Multiple OperatorGroups in namespace ${INSTALL_NAMESPACE}: $existing"
            oc -n "$INSTALL_NAMESPACE" get operatorgroup -o yaml || true
            return 1
        fi
        log "OperatorGroup already exists: $existing"
        return 0
    fi

    log "Creating OperatorGroup in ${INSTALL_NAMESPACE}..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: medik8s-og
  namespace: ${INSTALL_NAMESPACE}
spec:
  targetNamespaces:
  - ${INSTALL_NAMESPACE}
EOF
}

wait_for_package_manifest() {
    local pkg="$1"
    log "Waiting for PackageManifest ${pkg} in CatalogSource ${CATALOG_SOURCE_NAME}..."
    for i in $(seq 1 24); do
        if oc get packagemanifest -n openshift-marketplace \
            -l "catalog=${CATALOG_SOURCE_NAME}" \
            --field-selector "metadata.name=${pkg}" -o name 2>/dev/null | grep -q .; then
            log "PackageManifest ${pkg} found"
            return 0
        fi
        log "  attempt ${i}/24 — not found yet, waiting 5s..."
        sleep 5
    done
    log "ERROR: PackageManifest ${pkg} not found after 120s"
    oc get packagemanifest -n openshift-marketplace -l "catalog=${CATALOG_SOURCE_NAME}" || true
    return 1
}

create_subscription() {
    local pkg="$1"
    log "Creating Subscription for ${pkg} (channel: ${OO_CHANNEL}, source: ${CATALOG_SOURCE_NAME})..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${pkg}
  namespace: ${INSTALL_NAMESPACE}
spec:
  channel: ${OO_CHANNEL}
  name: ${pkg}
  source: ${CATALOG_SOURCE_NAME}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
}

wait_for_csv() {
    local pkg="$1"
    log "Waiting for CSV from subscription ${pkg}..."

    local csv=""
    for i in $(seq 1 60); do
        csv=$(oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [[ -n "$csv" ]]; then
            log "Found CSV: $csv"
            break
        fi
        sleep 10
    done

    if [[ -z "$csv" ]]; then
        log "ERROR: No CSV installed for subscription ${pkg} after 10m"
        log "--- Debug info ---"
        oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" -o yaml || true
        oc get installplan -n "$INSTALL_NAMESPACE" || true
        oc get events -n "$INSTALL_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
        return 1
    fi

    log "Waiting for CSV ${csv} to reach Succeeded phase..."
    if oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv}" \
        -n "$INSTALL_NAMESPACE" --timeout=5m; then
        log "CSV ${csv} is Succeeded"
        return 0
    fi

    log "ERROR: CSV ${csv} did not reach Succeeded within 5m"
    oc get csv "$csv" -n "$INSTALL_NAMESPACE" -o yaml || true
    return 1
}

wait_for_subscription() {
    local pkg="$1"
    for attempt in $(seq 1 5); do
        if oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" -o name &>/dev/null; then
            return 0
        fi
        log "  waiting for subscription ${pkg} to appear (attempt ${attempt}/5)..."
        sleep 2
    done
    return 1
}

main() {
    log "=== medik8s Operator Subscribe ==="
    trap 'collect_artifacts' EXIT
    set_proxy

    if [[ -z "$OPERATORS" ]]; then
        log "ERROR: OPERATORS env var is required (comma-separated OLM package names)"
        log "Example: OPERATORS=fence-agents-remediation,storage-based-remediation"
        exit 1
    fi

    if [[ -f "${SHARED_DIR}/catsrc_name" ]]; then
        CATALOG_SOURCE_NAME=$(cat "${SHARED_DIR}/catsrc_name")
        log "Using CatalogSource name from SHARED_DIR: ${CATALOG_SOURCE_NAME}"
    fi

    log "CatalogSource: ${CATALOG_SOURCE_NAME}"
    log "Channel: ${OO_CHANNEL}"
    log "Namespace: ${INSTALL_NAMESPACE}"
    log "Operators: ${OPERATORS}"

    ensure_namespace
    ensure_operatorgroup

    IFS=',' read -ra OPERATOR_LIST <<< "$OPERATORS"

    for pkg in "${OPERATOR_LIST[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        log ""
        log "--- Installing operator: ${pkg} ---"
        wait_for_package_manifest "$pkg" || exit 1
        create_subscription "$pkg"
    done

    local failed=0
    for pkg in "${OPERATOR_LIST[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        [[ -z "$pkg" ]] && continue
        if ! wait_for_subscription "$pkg"; then
            log "ERROR: Subscription ${pkg} does not exist in ${INSTALL_NAMESPACE}"
            failed=1
            continue
        fi
        if ! wait_for_csv "$pkg"; then
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        log "ERROR: One or more operators failed to install"
        oc get csv -n "$INSTALL_NAMESPACE" || true
        exit 1
    fi

    log ""
    log "=== All operators installed successfully ==="
    oc get csv -n "$INSTALL_NAMESPACE"
}
main
