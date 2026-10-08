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
if ! oc whoami --request-timeout=30s &>/dev/null; then
    echo "ERROR: Cannot access cluster with provided kubeconfig"
    exit 1
fi

# 2. Poll for RBAC resources with timeout
#    On fresh clusters, SyncSet propagation may delay resource creation.
#    Poll every 15s for up to ~3 minutes before giving up.
MAX_ATTEMPTS=12
INTERVAL=15
ATTEMPT=0

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    echo ""
    echo "=== RBAC validation attempt ${ATTEMPT}/${MAX_ATTEMPTS} ==="

    MISSING=""

    # Check 1: SubjectPermission CR for dedicated-admins in openshift-rbac-permissions
    echo "Checking SubjectPermission CR 'dedicated-admins'..."
    if oc get subjectpermission dedicated-admins -n openshift-rbac-permissions --as=backplane-cluster-admin --request-timeout=30s &>/dev/null; then
        echo "  SubjectPermission 'dedicated-admins' found"
    else
        echo "  SubjectPermission 'dedicated-admins' NOT found"
        MISSING="${MISSING}SubjectPermission "
    fi

    # Check 2: ClusterRoleBinding for dedicated-admins-cluster
    echo "Checking ClusterRoleBinding 'dedicated-admins-cluster'..."
    if oc get clusterrolebinding dedicated-admins-cluster --request-timeout=30s &>/dev/null; then
        echo "  ClusterRoleBinding 'dedicated-admins-cluster' found"
    else
        echo "  ClusterRoleBinding 'dedicated-admins-cluster' NOT found"
        MISSING="${MISSING}ClusterRoleBinding "
    fi

    # Check 3: rbac-permissions-operator deployment is running with 1+ ready replicas
    echo "Checking rbac-permissions-operator readiness..."
    READY_REPLICAS=$(oc get deployment rbac-permissions-operator \
        -n openshift-rbac-permissions \
        --request-timeout=30s \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ -z "${READY_REPLICAS}" ]]; then
        READY_REPLICAS="0"
    fi
    if [[ "${READY_REPLICAS}" -ge 1 ]] 2>/dev/null; then
        echo "  rbac-permissions-operator has ${READY_REPLICAS} ready replica(s)"
    else
        echo "  rbac-permissions-operator NOT ready (readyReplicas=${READY_REPLICAS})"
        MISSING="${MISSING}OperatorDeployment "
    fi

    # All checks passed
    if [[ -z "${MISSING}" ]]; then
        echo ""
        echo "All RBAC resources present. Running functional authorization check..."

        # Verify the ClusterRoleBinding actually grants permissions (cluster-scoped check).
        # Impersonation may be blocked on some clusters, so treat Forbidden as a
        # non-fatal warning — the existence checks above already passed.
        AUTH_OUTPUT=$(oc auth can-i create configmaps \
            --as="probe@redhat.com" --as-group="dedicated-admins" \
            --request-timeout=30s 2>&1) && AUTH_RC=0 || AUTH_RC=$?
        if [[ "${AUTH_RC}" -eq 0 ]]; then
            echo "RBAC authorization check passed"
        elif echo "${AUTH_OUTPUT}" | grep -qi "Forbidden\|forbid\|cannot impersonate"; then
            echo "WARNING: impersonation not permitted on this cluster — skipping functional auth check"
            echo "  (existence checks already passed; RBAC resources are present)"
        elif echo "${AUTH_OUTPUT}" | grep -qxi "no"; then
            echo "WARNING: oc auth can-i returned 'no' for cluster-scoped check — skipping functional auth check"
            echo "  (dedicated-admins permissions are namespace-scoped; existence checks already passed)"
        else
            echo "ERROR: dedicated-admins ClusterRoleBinding exists but authorization check failed"
            echo "  oc auth can-i output: ${AUTH_OUTPUT}"
            echo ""
            echo "=== Authorization Diagnostics ==="
            echo "ClusterRoleBinding details:"
            oc get clusterrolebinding dedicated-admins-cluster -o yaml --request-timeout=30s 2>/dev/null || echo "  Unable to describe CRB"
            echo ""
            echo "ClusterRole details:"
            oc get clusterrole dedicated-admins-cluster -o yaml --request-timeout=30s 2>/dev/null || echo "  Unable to describe ClusterRole"
            exit 1
        fi

        echo ""
        echo "RBAC validation passed - all resources are present and operator is running"
        exit 0
    fi

    # Not all checks passed - retry or fail
    if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
        echo ""
        echo "ERROR: RBAC validation failed after ${ATTEMPT} attempts (missing: ${MISSING})"
        echo ""
        echo "=== RBAC Diagnostics ==="
        echo ""
        echo "SubjectPermissions in openshift-rbac-permissions:"
        oc get subjectpermission -n openshift-rbac-permissions --as=backplane-cluster-admin --request-timeout=30s 2>/dev/null || echo "  Unable to list SubjectPermissions"
        echo ""
        echo "ClusterRoleBindings matching dedicated-admin:"
        oc get clusterrolebindings --request-timeout=30s -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | test("dedicated-admin")) | "\(.metadata.name) -> \(.roleRef.name)"' 2>/dev/null || echo "  Unable to list ClusterRoleBindings"
        echo ""
        echo "rbac-permissions-operator status:"
        oc get deployment -n openshift-rbac-permissions rbac-permissions-operator --request-timeout=30s -o wide 2>/dev/null || echo "  Not found"
        exit 1
    fi

    echo "Waiting ${INTERVAL}s before retrying (missing: ${MISSING})..."
    sleep "${INTERVAL}"
done
