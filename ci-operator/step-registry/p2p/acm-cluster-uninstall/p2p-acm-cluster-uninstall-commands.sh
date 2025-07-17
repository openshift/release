#!/bin/bash

set -euo pipefail

cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

#=====================

[[ -f "${SHARED_DIR}/managed.cluster.name" ]] || { echo "Spoke cluster name not found in file :${SHARED_DIR}/managed.cluster.name" >&2;}

CLUSTER_NAME="$(cat "${SHARED_DIR}/managed.cluster.name")"

echo "$CLUSTER_NAME"


#======optional
NAMESPACE="${CLUSTER_NAME}"
TIMEOUT_MINUTES="${TIMEOUT:-120}"
POLL_SECONDS="${POLL_SECONDS:-15}"
LOG_SINCE="${LOG_SINCE:-30s}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-true}"
FORCE_DELETE_MC="${FORCE_DELETE_MC:-false}"

#========helpers======
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found"; exit 1; }; }
jsonpath(){ oc -n "$NAMESPACE" get "$1" "$2" -o jsonpath="$3" 2>/dev/null || true; }
now(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }

need oc; need jq

echo "[INFO] $(now) Uninstalling cluster '${CLUSTER_NAME}' in namespace '${NAMESPACE}'"

#Sanity checks
oc get ns "$NAMESPACE" >/dev/null 2>&1 || { echo "[ERROR] Namespace '$NAMESPACE' not found"; exit 1; }
oc -n "$NAMESPACE" get clusterdeployment "$CLUSTER_NAME" >/dev/null 2>&1 || \
   echo "[WARN] ClusterDeployment '$CLUSTER_NAME' not found (maybe already deleted)"

#============ Step 1: Detach from ACM (ManagedCluster)============
if oc get managedcluster "$CLUSTER_NAME" >/dev/null 2>&1; then
   echo "[INFO] $(now) De-registering ManagedCluster '$CLUSTER_NAME' from ACM"
   #delete MC to stop agent sync
   if [[ "$FORCE_DELETE_MC" == "true" ]]; then
      echo "[WARN] Force deleteing MAangedCluster finalizers (if any)"
      oc patch managedcluster "$CLSUTER_NAME" --type=merge -p '{"metadata":{"finalizers":null}}' || true
   fi
   oc delete managedcluster "$CLUSTER_NAME" --ignore-not-found=true || true
else
   echo "[INFO] ManagedCluster '$CLUSTER_NAME' not present (already removed)"
fi

# Remove KlusterletAddonConfig if present
if oc -n "$NAMESPACE" get klusterletaddonconfig "$CLUSTER_NAME" >/dev/null 2>&1; then
   oc -n "$NAMESPACE" delete klusterletaddonconfig "$CLUSTER_NAME" --ignore-not-found=true || true
fi

#============ Step 2 : Ensure CD will deprovision infra =====
if oc -n "$NAMESPACE" get clusterdeployment "$CLUSTER_NAME" >/dev/null 2>&1; then
   echo "[INFO] $(now) Ensure preserveOnDelete=false so Hive tears down infra"
   oc -n "$NAMESPACE" patch clusterdeployment "$CLUSTER_NAME" --type=merge -p '{"spec":{"preserveOnDelete":false}}' || true
fi

#================ Ste 3 : Delete ClusterDeployment ========================
if oc -n "$NAMESPACE" get clusterdeployment "$CLUSTER_NAME" >/dev/null 2>&1; then
   echo "[INFO] $(now) Deleting Cluster deployment '$CLUSTER_NAME' "
   oc -n "$NAMESPACE" delete clusterdeployment "$CLUSTER_NAME" --cascade=foreground --wait=false
else
   echo "[INFO] ClusterDeployment already gone; if Hive created cluster deprovision earlier we will still watch logs."
fi

#============ step 4: watch deprovision progress & stream logs =============
deadline=$(( $(date +%s) + TIMEOUT_MINUTES*60 ))
STREAM_PID=""
CURRENT_POD=""

cleanup() {
    [[ -n "${STREAM_PID:-}" ]] && kill "${STREAM_PID}" 2>/dev/null || true
}

trap cleanup EXIT

start_stream() {
    local pod="$1"
    [[ -z "$pod" ]] && return 0
    [[ "$pod" == "$CURRENT_POD" ]] && return 0
    [[  -n "${STREAM_PID:-}" ]] && { kill "${STREAM_PID}" 2>/dev/null || true; wait "${STREAM_PID}" 2>/dev/null || true; }
    CURRENT_POD="$pod"
    echo
    echo "[INFO] $(now) Streaming deprovision logs from pod: $pod"
    ( oc -n "$NAMESPACE" logs "$pod" -f --since="${LOG_SINCE}" || true ) & STREAM_PID=$!
}

pick_deprovision_pod() {
    oc -n "$NAMESPACE" get pod -l hive.openshift.io/job-type=deprovision \
       -o jsonpath'{.items[0].metadata.name}' 2>/dev/null || true
}

get_clusterdeployement() {
    oc -n "$NAMESPACE" get clusterdeployment "$CLUSTER_NAME" >/dev/null 2>&1 && echo "yes" || echo "no"
}

# Deprovision CR
list_deprovision_crs() {
    oc -n "$NAMESPACE" get clusterdeprovisions -l hive.openshift.io/cluster-deployment-name="$CLUSTER_NAME" --no-headers 2>/dev/null || true
}

echo "[INFO] $(now) waiting for deprovision job to complete (timeout: ${TIMEOUT_MINUTES}m)_"
while true; do
#start or switch log stream if a provision pod exists
  POD="$(pick_deprovision_pod || true)"
  [[ -n "$POD" ]] && start_stream "$POD"

  #success
  cd_exists="$(get_clusterdeployement)"
  deprovision_running=$(oc -n "$NAMESPACE" get pod -l hive.openshift.io/job-type=deprovision --no-headers 2>/dev/null | wc -l | tr -d ' ')
  deprov_state="$(
    oc -n "$NAMESPACE" get clusterdeprovisions -o json 2>/dev/null \
    | jq -r '.items | sort_by(.metadata.creationTimestamp[-1].status.state // ""'
  )"

  if [[ "$cd_exists" == "no" && "${deprovision_running:-0}" == "0" ]]; then
    case "$deprov_state" in
      completed|"")
        echo
        echo "[INFO] $(now) Deprovision completed"
        break
        ;;
      failed)
        echo
        echo "[ERROR] $(now) Deprovison reported failed state"
        exit 2
        ;;
    esac
  fi

  #timeout
  if (( $(date +%s) > deadline )); then
    echo
    echo "[ERROR] $(now) Uninstall timed out after ${TIMEOUT_MINUTES} minutes"
    exit 3
  fi

  sleep "$POLL_SECONDS"
done

cleanup

    