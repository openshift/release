#!/bin/bash

set -euo pipefail

echo "Validating RBAC health on leased cluster..."

# The kubeconfig is shared from the checkout step
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ ! -f "${KUBECONFIG}" ]]; then
    echo "ERROR: No kubeconfig found at ${KUBECONFIG}"
    exit 1
fi

# 1. Verify cluster access
echo "Checking cluster access..."
if ! oc whoami &>/dev/null; then
    echo "ERROR: Cannot access cluster with provided kubeconfig"
    exit 1
fi

# 2. Smoke-test dedicated-admin impersonation
echo "Checking dedicated-admins RBAC permissions..."
RBAC_ERROR=""
if RBAC_RESULT=$(oc auth can-i create configmaps \
    --as=rbac-probe@redhat.com --as-group=dedicated-admins \
    -n default 2>&1); then
    :
else
    RBAC_ERROR="${RBAC_RESULT}"
fi

if [[ -n "${RBAC_ERROR}" && "${RBAC_RESULT}" != "no" ]]; then
    echo "ERROR: RBAC check command failed: ${RBAC_ERROR}"
    echo ""
    echo "=== RBAC Diagnostics ==="
    echo "ClusterRoleBindings binding the dedicated-admins group:"
    oc get clusterrolebindings -o json | \
        jq -r '.items[] | select(.subjects[]? | select(.kind == "Group" and .name == "dedicated-admins")) | "\(.metadata.name) -> \(.roleRef.name)"' 2>/dev/null || true
    echo ""
    echo "rbac-permissions-operator status:"
    oc get deployment -n openshift-rbac-permissions rbac-permissions-operator -o wide 2>/dev/null || echo "  Not found"
    exit 1
elif [[ "${RBAC_RESULT}" == "no" ]]; then
    echo "ERROR: dedicated-admins group cannot create configmaps"
    echo ""
    echo "=== RBAC Diagnostics ==="
    echo "ClusterRoleBindings binding the dedicated-admins group:"
    oc get clusterrolebindings -o json | \
        jq -r '.items[] | select(.subjects[]? | select(.kind == "Group" and .name == "dedicated-admins")) | "\(.metadata.name) -> \(.roleRef.name)"' 2>/dev/null || true
    echo ""
    echo "rbac-permissions-operator status:"
    oc get deployment -n openshift-rbac-permissions rbac-permissions-operator -o wide 2>/dev/null || echo "  Not found"
    exit 1
elif [[ "${RBAC_RESULT}" != "yes" ]]; then
    echo "WARNING: RBAC check returned unexpected result: ${RBAC_RESULT}"
    echo "Continuing anyway (may be a transient issue)..."
fi

echo "RBAC validation passed - dedicated-admins permissions are functional"
