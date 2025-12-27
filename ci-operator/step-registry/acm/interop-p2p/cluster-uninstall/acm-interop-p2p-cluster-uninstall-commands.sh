#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit
#=====================
# if no spoke clusters in acm then exit
mapfile -t ALL_SPOKES < <(oc get managedcluster -o json | jq -r '.items[] | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#ALL_SPOKES[@]} -eq 0 ]]; then
  info "No spoke clusters found"
  exit 0
fi

[[ -f "${SHARED_DIR}/managed.cluster.name" ]] || { echo "Spoke cluster name not found in file :${SHARED_DIR}/managed.cluster.name" >&2; exit 0;}

cluster_name="$(cat "${SHARED_DIR}/managed.cluster.name")"

#======optional
namespace="${cluster_name}"
timeout_minutes="60"  # Default deprovisioning timeout
poll_seconds="10"       # Polling interval for checks
force_delete_mc="false"

#========helpers======
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
need oc; need jq

echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'"

# Function to check for cluster existence and set cleanup trap
function setup_teardown() {
    # Check if namespace exists
    oc get ns "$namespace" >/dev/null 2>&1 || { echo "[ERROR] Namespace '$namespace' not found"; exit 1; }

    #oc -n "$namespace" patch clusterdeployment "$cluster_name" --type=merge -p '{"spec":{"clusterMetadata":{"metadataJSONSecretRef":null}}}'

    # Check if ClusterDeployment exists (it might be already deleted by a previous step)
    if ! oc -n "$namespace" get clusterdeployment "$cluster_name" >/dev/null 2>&1; then
        echo "[INFO] ClusterDeployment '$cluster_name' not present (already removed). Proceeding with ManagedCluster check."
    fi
}

# Function to pick the latest ClusterDeprovision resource for watching progress
pick_latest_deprov_name() {
    oc -n "${namespace}" get clusterdeprovisions -o json 2>/dev/null \
    | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
}

# --- Execution Starts ---
setup_teardown

echo "[INFO] Detach from ACM (ManagedCluster) and clean up Klusterlet config "
if oc get managedcluster "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] Deleting ManagedCluster '$cluster_name' from ACM (this is the primary deletion step)"

   if [[ "${force_delete_mc}" == "true" ]]; then
      echo "[WARN] Force deleting ManagedCluster finalizers (if any)"
      oc patch managedcluster "$cluster_name" --type=merge -p '{"metadata":{"finalizers":null}}'
   fi

   # Deleting ManagedCluster is the signal to ACM to detach the cluster
   oc delete managedcluster "$cluster_name" --ignore-not-found=true
else
   echo "[INFO] ManagedCluster '$cluster_name' not present (already removed)"
fi

# KlusterletAddonConfig cleanup (optional, but good practice)
if oc -n "$namespace" get klusterletaddonconfig "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] Deleting KlusterletAddonConfig '$cluster_name'"
   oc -n "$namespace" delete klusterletaddonconfig "$cluster_name" --ignore-not-found=true
fi


echo "-[INFO] Ensure ClusterDeployment triggers infrastructure deprovisioning "
# Check if ClusterDeployment still exists before trying to patch/delete it
if oc -n "$namespace" get clusterdeployment "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] Patching ClusterDeployment '$cluster_name' to ensure preserveOnDelete=false"
   # Patching preserveOnDelete to false ensures Hive tears down infrastructure
   oc -n "$namespace" patch clusterdeployment "$cluster_name" --type=merge -p '{"spec":{"preserveOnDelete":false}}'

   echo "[INFO] Deleting ClusterDeployment '$cluster_name' to initiate deprovisioning"
   # Deleting CD triggers the creation of a ClusterDeprovision object by Hive
   oc -n "$namespace" delete clusterdeployment "$cluster_name" --wait=false   

else
   echo "[INFO] ClusterDeployment already gone, proceeding to check deprovision status."
fi


echo "[INFO] Watch deprovision progress (ClusterDeprovision resource)"
deadline=$(( $(date +%s) + timeout_minutes*60 ))
deprov_name=""

echo "[INFO] Waiting for ClusterDeprovision object to be created..."
# Wait for the ClusterDeprovision object to be created by Hive
while [[ -z "${deprov_name}" ]]; do
  deprov_name="$(pick_latest_deprov_name)"
  if [[ -n "${deprov_name}" ]]; then
    echo "[INFO] Found ClusterDeprovision: ${deprov_name}"
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "[ERROR] Timeout waiting for ClusterDeprovision object creation."
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
