#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Check if spoke clusters exist in ACM
#=====================
typeset managed_cluster_json
managed_cluster_json="$(oc get managedcluster -o json 2>/dev/null || echo '{"items":[]}')"
mapfile -t all_spokes < <(echo "${managed_cluster_json}" | jq -r '.items[]? | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#all_spokes[@]} -eq 0 ]]; then
    echo "[INFO] No spoke clusters found"
    exit 0
fi

#=====================
# Validate required files and variables
#=====================
if [[ ! -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    echo "[ERROR] Spoke cluster name not found in file: ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

typeset cluster_name
cluster_name="$(cat "${SHARED_DIR}/managed-cluster-name")"
typeset namespace="${cluster_name}"
typeset timeout_minutes="60"  # Default deprovisioning timeout
typeset poll_seconds="10"     # Polling interval for checks
typeset force_delete_mc="false"

#=====================
# Setup and validation functions
#=====================
SetupTeardown() {
    # Check if namespace exists
    if ! oc get ns "${namespace}" >/dev/null 2>&1; then
        echo "[ERROR] Namespace '${namespace}' not found" >&2
        exit 1
    fi

    # Check if ClusterDeployment exists (it might be already deleted by a previous step)
    if ! oc -n "${namespace}" get clusterdeployment "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] ClusterDeployment '${cluster_name}' not present (already removed). Proceeding with ManagedCluster check."
    fi
    true
}

# Function to pick the latest ClusterDeprovision resource for watching progress
PickLatestDeprovName() {
    typeset deprov_json
    deprov_json="$(oc -n "${namespace}" get clusterdeprovisions -o json 2>/dev/null || echo '{"items":[]}')"
    echo "${deprov_json}" | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
    true
}

echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'"

#=====================
# Execution starts
#=====================
SetupTeardown

#=====================
# Detach from ACM (ManagedCluster) and clean up Klusterlet config
#=====================
echo "[INFO] Detaching from ACM (ManagedCluster) and cleaning up Klusterlet config"
if oc get managedcluster "${cluster_name}" >/dev/null 2>&1; then
    echo "[INFO] Deleting ManagedCluster '${cluster_name}' from ACM (this is the primary deletion step)"

    if [[ "${force_delete_mc}" == "true" ]]; then
        echo "[WARN] Force deleting ManagedCluster finalizers (if any)"
        oc patch managedcluster "${cluster_name}" --type=merge -p '{"metadata":{"finalizers":null}}'
    fi

    # Deleting ManagedCluster is the signal to ACM to detach the cluster
    oc delete managedcluster "${cluster_name}" --ignore-not-found=true
else
    echo "[INFO] ManagedCluster '${cluster_name}' not present (already removed)"
fi

# KlusterletAddonConfig cleanup (optional, but good practice)
if oc -n "${namespace}" get klusterletaddonconfig "${cluster_name}" >/dev/null 2>&1; then
    echo "[INFO] Deleting KlusterletAddonConfig '${cluster_name}'"
    oc -n "${namespace}" delete klusterletaddonconfig "${cluster_name}" --ignore-not-found=true
fi

#=====================
# Ensure ClusterDeployment triggers infrastructure deprovisioning
#=====================
echo "[INFO] Ensuring ClusterDeployment triggers infrastructure deprovisioning"
# Check if ClusterDeployment still exists before trying to patch/delete it
if oc -n "${namespace}" get clusterdeployment "${cluster_name}" >/dev/null 2>&1; then
    echo "[INFO] Patching ClusterDeployment '${cluster_name}' to ensure preserveOnDelete=false"
    # Patching preserveOnDelete to false ensures Hive tears down infrastructure
    oc -n "${namespace}" patch clusterdeployment "${cluster_name}" --type=merge -p '{"spec":{"preserveOnDelete":false}}'

    echo "[INFO] Deleting ClusterDeployment '${cluster_name}' to initiate deprovisioning"
    # Deleting CD triggers the creation of a ClusterDeprovision object by Hive
    oc -n "${namespace}" delete clusterdeployment "${cluster_name}" --wait=false
else
    echo "[INFO] ClusterDeployment already gone, proceeding to check deprovision status."
fi

#=====================
# Watch deprovision progress (ClusterDeprovision resource)
#=====================
echo "[INFO] Watching deprovision progress (ClusterDeprovision resource)"
typeset start_time
start_time="$(date +%s)"
typeset deadline=$((start_time + timeout_minutes * 60))
typeset deprov_name=""

echo "[INFO] Waiting for ClusterDeprovision object to be created..."
# Wait for the ClusterDeprovision object to be created by Hive
while [[ -z "${deprov_name}" ]]; do
    deprov_name="$(PickLatestDeprovName)"
    if [[ -n "${deprov_name}" ]]; then
        echo "[INFO] Found ClusterDeprovision: ${deprov_name}"
        break
    fi
    if (( $(date +%s) > deadline )); then
        echo "[ERROR] Timeout waiting for ClusterDeprovision object creation." >&2
        exit 3
    fi
    sleep "${poll_seconds}"
done

echo "[INFO] Waiting for ClusterDeprovision '${deprov_name}'.status.completed=true (timeout=${timeout_minutes}m)"

# Use oc wait to poll the resource status efficiently
oc -n "${namespace}" wait \
    --for=jsonpath='{.status.completed}'=true \
    "clusterdeprovision/${deprov_name}" \
    --timeout="${timeout_minutes}m"

echo "[INFO] Cluster deprovisioning completed successfully."
