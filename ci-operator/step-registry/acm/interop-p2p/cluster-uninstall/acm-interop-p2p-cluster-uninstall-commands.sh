#!/bin/bash
#
# ACM Spoke Cluster Uninstall Script
#
# Uninstalls one or more ACM spoke clusters by deleting ManagedCluster,
# ClusterDeployment, and related resources. Reads cluster names from:
#   - managed-cluster-names (preferred, one name per line for multi-cluster)
#   - managed-cluster-name-{N} (indexed files from cluster-install)
#   - managed-cluster-name (fallback for single-cluster backward compatibility)
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Check if spoke clusters exist in ACM
#=====================
managed_cluster_json="$(oc get managedcluster -o json 2>/dev/null || echo '{"items":[]}')"
mapfile -t all_spokes < <(echo "${managed_cluster_json}" | jq -r '.items[]? | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#all_spokes[@]} -eq 0 ]]; then
    echo "[INFO] No spoke clusters found"
    exit 0
fi

#=====================
# Load cluster names to uninstall
#=====================
# Prefer managed-cluster-names (multi-cluster), then indexed files, then managed-cluster-name (single-cluster)
typeset -a clusters_to_uninstall=()
if [[ -f "${SHARED_DIR}/managed-cluster-names" ]]; then
    mapfile -t clusters_to_uninstall < <(grep -v '^[[:space:]]*$' "${SHARED_DIR}/managed-cluster-names" || true)
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-names"
elif [[ -f "${SHARED_DIR}/managed-cluster-name-1" ]]; then
    typeset idx=1
    while [[ -f "${SHARED_DIR}/managed-cluster-name-${idx}" ]]; do
        clusters_to_uninstall+=("$(cat "${SHARED_DIR}/managed-cluster-name-${idx}")")
        ((++idx))
    done
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-name-{N} files"
elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    clusters_to_uninstall=("$(cat "${SHARED_DIR}/managed-cluster-name")")
    echo "[INFO] Loaded 1 cluster from managed-cluster-name (single-cluster mode)"
else
    echo "[ERROR] No cluster name file found. Expected one of: managed-cluster-names, managed-cluster-name-1, or managed-cluster-name" >&2
    exit 1
fi

if [[ ${#clusters_to_uninstall[@]} -eq 0 ]]; then
    echo "[ERROR] No cluster names to uninstall" >&2
    exit 1
fi

timeout_minutes="60"  # Default deprovisioning timeout per cluster
poll_seconds="10"     # Polling interval for checks
force_delete_mc="false"

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
    true
}

PickLatestDeprovName() {
    typeset namespace="$1"
    typeset deprov_json
    deprov_json="$(oc -n "${namespace}" get clusterdeprovisions -o json 2>/dev/null || echo '{"items":[]}')"
    echo "${deprov_json}" | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
}

#=====================
# UninstallCluster - Uninstall a single spoke cluster
#=====================
UninstallCluster() {
    typeset cluster_name="$1"
    typeset namespace="${cluster_name}"

    echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'"

    # Check if namespace exists
    if ! oc get ns "${namespace}" >/dev/null 2>&1; then
        echo "[WARN] Namespace '${namespace}' not found, cluster may already be removed. Skipping." >&2
        return 0
    fi

    # Detach from ACM (ManagedCluster) and clean up Klusterlet config
    echo "[INFO] Detaching from ACM (ManagedCluster) and cleaning up Klusterlet config for '${cluster_name}'"
    if oc get managedcluster "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting ManagedCluster '${cluster_name}' from ACM (this is the primary deletion step)"
        if [[ "${force_delete_mc}" == "true" ]]; then
            echo "[WARN] Force deleting ManagedCluster finalizers (if any)"
            oc patch managedcluster "${cluster_name}" --type=merge -p '{"metadata":{"finalizers":null}}'
        fi
        oc delete managedcluster "${cluster_name}" --ignore-not-found=true
    else
        echo "[INFO] ManagedCluster '${cluster_name}' not present (already removed)"
    fi

    if oc -n "${namespace}" get klusterletaddonconfig "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting KlusterletAddonConfig '${cluster_name}'"
        oc -n "${namespace}" delete klusterletaddonconfig "${cluster_name}" --ignore-not-found=true
    fi

    # Ensure ClusterDeployment triggers infrastructure deprovisioning
    echo "[INFO] Ensuring ClusterDeployment triggers infrastructure deprovisioning for '${cluster_name}'"
    if oc -n "${namespace}" get clusterdeployment "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Patching ClusterDeployment '${cluster_name}' to ensure preserveOnDelete=false"
        oc -n "${namespace}" patch clusterdeployment "${cluster_name}" --type=merge -p '{"spec":{"preserveOnDelete":false}}'
        echo "[INFO] Deleting ClusterDeployment '${cluster_name}' to initiate deprovisioning"
        oc -n "${namespace}" delete clusterdeployment "${cluster_name}" --wait=false
    else
        echo "[INFO] ClusterDeployment '${cluster_name}' already gone, proceeding to check deprovision status."
    fi

    # Watch deprovision progress (ClusterDeprovision resource)
    echo "[INFO] Watching deprovision progress for '${cluster_name}'"
    typeset start_time
    start_time="$(date +%s)"
    typeset deadline
    deadline=$((start_time + timeout_minutes * 60))
    typeset deprov_name=""

    echo "[INFO] Waiting for ClusterDeprovision object to be created for '${cluster_name}'..."
    while [[ -z "${deprov_name}" ]]; do
        deprov_name="$(PickLatestDeprovName "${namespace}")"
        if [[ -n "${deprov_name}" ]]; then
            echo "[INFO] Found ClusterDeprovision: ${deprov_name}"
            break
        fi
        if (( $(date +%s) > deadline )); then
            echo "[ERROR] Timeout waiting for ClusterDeprovision object creation for '${cluster_name}'." >&2
            return 3
        fi
        sleep "${poll_seconds}"
    done

    echo "[INFO] Waiting for ClusterDeprovision '${deprov_name}'.status.completed=true (timeout=${timeout_minutes}m)"
    oc -n "${namespace}" wait \
        --for=jsonpath='{.status.completed}'=true \
        "clusterdeprovision/${deprov_name}" \
        --timeout="${timeout_minutes}m"

    echo "[INFO] Cluster '${cluster_name}' deprovisioning completed successfully."

    # Delete ManagedClusterSet (cluster-scoped, created per cluster)
    typeset mc_set_name="${cluster_name}-set"
    if oc get managedclusterset "${mc_set_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting ManagedClusterSet '${mc_set_name}'"
        oc delete managedclusterset "${mc_set_name}" --ignore-not-found=true
    fi

    true
}

Need oc
Need jq

#=====================
# Uninstall all clusters
#=====================
echo "[INFO] Uninstalling ${#clusters_to_uninstall[@]} spoke cluster(s): ${clusters_to_uninstall[*]}"

typeset failed=0
for cluster_name in "${clusters_to_uninstall[@]}"; do
    cluster_name="$(echo "${cluster_name}" | tr -d '\n\r')"
    if [[ -z "${cluster_name}" ]]; then
        continue
    fi
    if ! UninstallCluster "${cluster_name}"; then
        echo "[ERROR] Failed to uninstall cluster '${cluster_name}'" >&2
        ((failed++)) || true
    fi
done

if [[ "${failed}" -gt 0 ]]; then
    echo "[ERROR] ${failed} cluster(s) failed to uninstall" >&2
    exit 3
fi

echo "[INFO] All ${#clusters_to_uninstall[@]} spoke cluster(s) deprovisioned successfully."
true
