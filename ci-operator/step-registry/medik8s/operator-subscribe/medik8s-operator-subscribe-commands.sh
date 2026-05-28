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

set_proxy() {
    [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] && {
        echo "setting proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    }
    return 0
}

ensure_namespace() {
    echo "Ensuring namespace ${INSTALL_NAMESPACE}..."
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
            echo "ERROR: Multiple OperatorGroups in namespace ${INSTALL_NAMESPACE}: $existing"
            oc -n "$INSTALL_NAMESPACE" get operatorgroup -o yaml || true
            return 1
        fi
        echo "OperatorGroup already exists: $existing"
        return 0
    fi

    echo "Creating OperatorGroup in ${INSTALL_NAMESPACE}..."
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
    echo "Waiting for PackageManifest ${pkg} in CatalogSource ${CATALOG_SOURCE_NAME}..."
    for i in $(seq 1 24); do
        if oc get packagemanifest -n openshift-marketplace \
            -l "catalog=${CATALOG_SOURCE_NAME}" \
            --field-selector "metadata.name=${pkg}" -o name 2>/dev/null | grep -q .; then
            echo "PackageManifest ${pkg} found"
            return 0
        fi
        echo "  attempt ${i}/24 — not found yet, waiting 5s..."
        sleep 5
    done
    echo "ERROR: PackageManifest ${pkg} not found after 120s"
    oc get packagemanifest -n openshift-marketplace -l "catalog=${CATALOG_SOURCE_NAME}" || true
    return 1
}

create_subscription() {
    local pkg="$1"
    echo "Creating Subscription for ${pkg} (channel: ${OO_CHANNEL}, source: ${CATALOG_SOURCE_NAME})..."
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
    echo "Waiting for CSV from subscription ${pkg}..."

    local csv=""
    for i in $(seq 1 60); do
        csv=$(oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" \
            -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [[ -n "$csv" ]]; then
            echo "Found CSV: $csv"
            break
        fi
        sleep 10
    done

    if [[ -z "$csv" ]]; then
        echo "ERROR: No CSV installed for subscription ${pkg} after 10m"
        echo "--- Debug info ---"
        oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" -o yaml || true
        oc get installplan -n "$INSTALL_NAMESPACE" || true
        oc get events -n "$INSTALL_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
        return 1
    fi

    echo "Waiting for CSV ${csv} to reach Succeeded phase..."
    if oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${csv}" \
        -n "$INSTALL_NAMESPACE" --timeout=5m; then
        echo "CSV ${csv} is Succeeded"
        return 0
    fi

    echo "ERROR: CSV ${csv} did not reach Succeeded within 5m"
    oc get csv "$csv" -n "$INSTALL_NAMESPACE" -o yaml || true
    return 1
}

main() {
    echo "=== medik8s Operator Subscribe ==="
    set_proxy

    if [[ -z "$OPERATORS" ]]; then
        echo "ERROR: OPERATORS env var is required (comma-separated OLM package names)"
        echo "Example: OPERATORS=fence-agents-remediation,storage-based-remediation"
        exit 1
    fi

    if [[ -f "${SHARED_DIR}/catsrc_name" ]]; then
        CATALOG_SOURCE_NAME=$(cat "${SHARED_DIR}/catsrc_name")
        echo "Using CatalogSource name from SHARED_DIR: ${CATALOG_SOURCE_NAME}"
    fi

    echo "CatalogSource: ${CATALOG_SOURCE_NAME}"
    echo "Channel: ${OO_CHANNEL}"
    echo "Namespace: ${INSTALL_NAMESPACE}"
    echo "Operators: ${OPERATORS}"

    ensure_namespace
    ensure_operatorgroup

    IFS=',' read -ra OPERATOR_LIST <<< "$OPERATORS"

    for pkg in "${OPERATOR_LIST[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        echo ""
        echo "--- Installing operator: ${pkg} ---"
        wait_for_package_manifest "$pkg" || exit 1
        create_subscription "$pkg"
    done

    sleep 10

    local failed=0
    for pkg in "${OPERATOR_LIST[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        if ! oc get subscription "$pkg" -n "$INSTALL_NAMESPACE" -o name &>/dev/null; then
            echo "ERROR: Subscription ${pkg} does not exist in ${INSTALL_NAMESPACE}"
            failed=1
            continue
        fi
        if ! wait_for_csv "$pkg"; then
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        echo "ERROR: One or more operators failed to install"
        oc get csv -n "$INSTALL_NAMESPACE" || true
        exit 1
    fi

    echo ""
    echo "=== All operators installed successfully ==="
    oc get csv -n "$INSTALL_NAMESPACE"
}
main
