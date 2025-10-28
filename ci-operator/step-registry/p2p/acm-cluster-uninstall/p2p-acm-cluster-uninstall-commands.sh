#!/bin/bash

set -euo pipefail

cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

#=====================
# if no spoke clusters in acm then exit
mapfile -t ALL_SPOKES < <(oc get managedcluster -o json | jq -r '.items[] | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#ALL_SPOKES[@]} -eq 0 ]]; then
  info "No spoke clusters found"
  exit 0
fi

[[ -f "${SHARED_DIR}/managed.cluster.name" ]] || { echo "Spoke cluster name not found in file :${SHARED_DIR}/managed.cluster.name" >&2;}

CLUSTER_NAME="$(cat "${SHARED_DIR}/managed.cluster.name")"

echo "$CLUSTER_NAME"


#======optional
NAMESPACE="${CLUSTER_NAME}"
TIMEOUT_MINUTES="${TIMEOUT:-40}"
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

#cleanup() {
    #[[ -n "${STREAM_PID:-}" ]] && kill "${STREAM_PID}" 2>/dev/null || true
#}

#trap cleanup EXIT

pick_deprovision_pod() {
    oc -n $NAMESPACE get pod -l hive.openshift.io/job-type=deprovision -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

get_clusterdeployement() {
    oc -n $NAMESPACE get clusterdeployment "$CLUSTER_NAME" >/dev/null 2>&1 && echo "yes" || echo "no"
}

# Deprovision CR
list_deprovision_crs() {
    oc -n $NAMESPACE get clusterdeprovisions -l hive.openshift.io/cluster-deployment-name="$CLUSTER_NAME" --no-headers 2>/dev/null || true
}

state_from_cd() {
   oc -n "${NAMESPACE}" get clusterdeprovisions -o json 2>/dev/null \
   | jq -r '
        (.items | sort_by(.metadata.creationTimestamp)[-1]? // {}) as $obj
        | if ($obj == {}) then "none"
          elif ($obj.status.completed == true) then "completed"
          elif ([$obj.status.conditions[]? | select(.type=="DeprovisionFailed" and .status=="True")] | length) > 0 then "failed"
          elif ([$obj.status.conditions[]? | select(.type=="AuthenticationFailure" and .status=="True")] | length) > 0 then "auth-failed"
          else "running" end
     '
}

# get deprovison logs from deprovision pod, display logs on the console
start_stream() {
    local pod="$1"
    [[ -z "$pod" ]] && return 0
    [[ "$pod" == "$CURRENT_POD" ]] && return 0
    [[  -n "${STREAM_PID:-}" ]] && { kill "${STREAM_PID}" 2>/dev/null || true; wait "${STREAM_PID}" 2>/dev/null || true; }
    CURRENT_POD="$pod"
    sleep 10
    echo
    echo "[INFO] $(now) Streaming logs from pod: $pod"
   #  oc -n "$NAMESPACE" logs "$POD" -f --since="${LOG_SINCE}" 2>&1  &  
    oc -n "$CLUSTER_NAME" logs "$CURRENT_POD" -f --since="${LOG_SINCE}" 2>&1  & STREAM_PID=$!
}

stop_stream() {
   [[ -n "${STREAM_PID:-}" ]] && { kill "$STREAM_PID" 2>/dev/null || true; wait "$STREAM_PID" 2>/dev/null || true; }
   STREAM_PID=""
   CURRENT_POD=""
}

sleep 10

# wait for deprovisoin and stream logs since the deprovision pod is running on hub cluster
echo "[INFO] $(now) waiting for deprovision job to complete (timeout: ${TIMEOUT_MINUTES}m)"

# POD="$(pick_deprovision_pod)"
# echo "deprovision-pod: $POD"

while true; do
#start or switch log stream if a provision pod exists
  
  
  state="$(state_from_cd)"
  echo "CD state: $state"
  case "$state" in 
    completed|none)
       echo 
       echo "[info] Deprovision completed."
       [[ -n "${STREAM_PID}" ]] && kill "$STREAM_PID" 2>dev/null || true
       exit 0
       ;;
    failed|auth-failed)
       echo
       echo "[ERROR] Deprovision failed (state=$state)."
       [[ -n "${STREAM_PID}" ]] && kill "$STREAM_PID" 2>dev/null || true
       exit 2
       ;; 
  esac
  if (( $(date +%s) > deadline )); then
    echo
    echo "[ERROR]Uninstall timed out after ${TIMEOUT_MINUTES} minutes."
    [[ -n "${STREAM_PID}" ]] && kill "$STREAM_PID" 2>dev/null || true
    exit 3
  fi
  POD="$(pick_deprovision_pod)"
  echo "deprovision-pod: $POD"
  if [[ -n "$POD" ]] ; then
    start_stream "$POD"
  fi

  if [[ -n "$CURRENT_POD" ]]; then
    if ! oc -n "$CLUSTER_NAME" get pod "$CURRENT_POD" >/dev/null 2>&1; then

      echo "[INFO] Deporvison pod not found stopping stream, waiting for next"
      stop_stream
    fi
  fi    

  sleep "$POLL_SECONDS"
done


    