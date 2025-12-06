#!/bin/bash

set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

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
namespace=${cluster_name}
timeout_minutes="60"
poll_seconds="15"
# LOG_SINCE="30s"
# DELETE_NAMESPACE="true"
force_delete_mc="false"

#========helpers======
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
need oc; need jq

echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'"

#Sanity checks
oc get ns "$namespace" >/dev/null 2>&1 || { echo "[ERROR] Namespace '$namespace' not found"; exit 1; }
oc -n "$namespace" get clusterdeployment "$cluster_name" >/dev/null 2>&1 || \
   echo "[WARN] ClusterDeployment '$cluster_name' not found (maybe already deleted)"

#============ Step 1: Detach from ACM (ManagedCluster)============
if oc get managedcluster "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] De-registering ManagedCluster '$cluster_name' from ACM"
   #delete MC to stop agent sync
   if [[ "${force_delete_mc}" == "true" ]]; then
      echo "[WARN] Force deleteing MAangedCluster finalizers (if any)"
      oc patch managedcluster "$cluster_name" --type=merge -p '{"metadata":{"finalizers":null}}'
   fi
   oc delete managedcluster "$cluster_name" --ignore-not-found=true
else
   echo "[INFO] ManagedCluster '$cluster_name' not present (already removed)"
fi

# Remove KlusterletAddonConfig if present
if oc -n "$namespace" get klusterletaddonconfig "$cluster_name" >/dev/null 2>&1; then
   oc -n "$namespace" delete klusterletaddonconfig "$cluster_name" --ignore-not-found=true
fi

#============ Step 2 : Ensure CD will deprovision infra =====
if oc -n "$namespace" get clusterdeployment "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] Ensure preserveOnDelete=false so Hive tears down infra"
   oc -n "$namespace" patch clusterdeployment "$cluster_name" --type=merge -p '{"spec":{"preserveOnDelete":false}}'
fi

#================ Ste 3 : Delete ClusterDeployment ========================
if oc -n "$namespace" get clusterdeployment "$cluster_name" >/dev/null 2>&1; then
   echo "[INFO] Deleting Cluster deployment '$cluster_name' "
   oc -n "$namespace" delete clusterdeployment "$cluster_name" --cascade=foreground --wait=false
else
   echo "[INFO] ClusterDeployment already gone; if Hive created cluster deprovision earlier we will still watch logs."
fi

#============ step 4: watch deprovision progress & stream logs =============
deadline=$(( $(date +%s) + timeout_minutes*60 ))

pick_latest_deprov_name() {
    oc -n "${namespace}" get clusterdeprovisions -o json 2>/dev/null \
    | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
}

echo "Waiting for cluster deprovision to be created"

deprov_name=""
while [[ -z "${deprov_name}" ]]; do
  deprov_name="$(pick_latest_deprov_name)"
  if [[ -n "${deprov_name}" ]]; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "Timeout waiting for ClusterDeprovision object."
    exit 3
  fi
  sleep "${poll_seconds}"
done

echo "Waiting for ClusterDeprovision.status.completed=true (timeout=${timeout_minutes}m)"

oc -n "${namespace}" wait --for=jsonpath='{.status.completed}'=true "clusterdeprovision/${deprov_name}" --timeout="${timeout_minutes}m"
