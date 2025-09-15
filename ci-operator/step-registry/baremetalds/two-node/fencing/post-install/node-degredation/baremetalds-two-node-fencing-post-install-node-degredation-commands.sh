#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# logging first (so it's usable everywhere)
log(){ echo "[$(date +'%F %T%z')] $*"; }

echo "[INFO] degraded two-node fencing pre step starting..."

ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"

FORCE_DOWNSHIFT="${FORCE_DOWNSHIFT:-true}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

# --- ensure oc client is present (no root required) ---
if ! command -v oc >/dev/null 2>&1; then
  log "oc not found, installing client..."
  CLI_TAG_LOCAL="${CLI_TAG:-4.20}"
  UNAME_M="$(uname -m)"
  case "$UNAME_M" in
    x86_64)   OC_TARBALL="openshift-client-linux.tar.gz" ;;
    aarch64|arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
    *)        log "Unsupported arch: $UNAME_M"; exit 1 ;;
  esac
  url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
  mkdir -p /tmp/ocbin
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
  else
    wget -qO- "$url" | tar -xz -C /tmp/ocbin oc
  fi
  chmod +x /tmp/ocbin/oc || true
  export PATH="/tmp/ocbin:$PATH"
  hash -r
fi

# --- global timebox (110 min) ---
GLOBAL_DEADLINE=$(( $(date +%s) + 6600 ))
must_have_time(){ [[ $((GLOBAL_DEADLINE-$(date +%s))) -gt 60 ]] || { log "Timebox hit, exiting clean."; exit 0; }; }

# --- pick survivor ---
SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
echo "$SURV" > "${ART_BASE}/survivor.txt"
log "Survivor: $SURV"

# --- pin probe helper ---
probe_pod(){
  local name=$1 duration=$2
  must_have_time
  local nsjson; nsjson=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "$SURV")
  oc -n openshift-image-registry delete pod "$name" --ignore-not-found --wait=false
  oc -n openshift-image-registry run "$name" --overrides="$nsjson" --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
    bash -lc "
      for i in \$(seq 1 $duration); do
        date '+%F %T'
        getent hosts image-registry.openshift-image-registry.svc || true
        code=\$(curl -sk -o /dev/null -w '%{http_code}' https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)
        echo REGISTRY:\$code
        sleep 2
      done" | tee "${ART_BASE}/${name}.log"
  oc -n openshift-image-registry delete pod "$name" --ignore-not-found --wait=false
}

# --- degrade node 1 ---
if [[ -e "${SHARED_DIR}/packet-conf.sh" ]]; then source "${SHARED_DIR}/packet-conf.sh"; fi
if [[ -n "${IP:-}" ]]; then
  log "Shutting down ostest_master_1..."
  ssh -o StrictHostKeyChecking=no root@"$IP" "virsh destroy ostest_master_1 || true"
fi

# --- probes ---
probe_pod precheck 150
probe_pod postcheck 300

# --- registry mitigation ---
must_have_time
log "Forcing registry single replica on $SURV"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p "{
  \"spec\": {
    \"replicas\": 1,
    \"managementState\": \"Managed\",
    \"nodeSelector\": {\"kubernetes.io/hostname\":\"$SURV\"},
    \"tolerations\": [],
    \"storage\": {\"emptyDir\":{}}
  }
}" || true

oc -n openshift-image-registry patch deploy/image-registry --type=merge -p "{
  \"spec\": {
    \"replicas\": 1,
    \"strategy\": {\"type\":\"Recreate\"},
    \"template\": {\"spec\": {
      \"nodeSelector\": {\"kubernetes.io/hostname\":\"$SURV\"},
      \"affinity\": null,
      \"topologySpreadConstraints\": null
    }}
  }
}" || true

# nuke pods on NotReady nodes
NNR=$(oc get nodes | awk '$2!="Ready"{print $1}')
for nn in $NNR; do
  pod=$(oc -n openshift-image-registry get pod -o wide 2>/dev/null | awk -v N="$nn" '$1 ~ /^image-registry-/ && $7==N {print $1;exit}')
  [[ -n "$pod" ]] && oc -n openshift-image-registry delete pod "$pod" --force --grace-period=0 || true
done

# bounded wait: max 20 min
deadline=$(( $(date +%s) + 1200 ))
while [[ $(date +%s) -lt $deadline ]]; do
  must_have_time
  if oc -n openshift-image-registry get pod -o wide 2>/dev/null \
     | awk -v N="$SURV" '$1~/^image-registry-/ && $3=="Running"{running[$7]++}
       END{ok=(running[N]==1); for(n in running) if(n!=N && running[n]>0) ok=0; exit !ok}'; then
    log "Registry stable: 1 pod on $SURV"
    break
  fi
  sleep 10
done

# --- OCM (controller-manager) ---
if oc -n openshift-controller-manager get deploy/controller-manager >/dev/null 2>&1; then
  oc -n openshift-controller-manager patch deploy/controller-manager --type=merge -p "{
    \"spec\": {
      \"replicas\": 1,
      \"strategy\": {\"type\":\"Recreate\"},
      \"template\": {\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\":\"$SURV\"}}}
    }
  }" || true
  oc -n openshift-controller-manager delete pod -l app=openshift-controller-manager --force --grace-period=0 || true
fi

# --- OLM (packageserver) ---
if oc -n openshift-operator-lifecycle-manager get deploy/packageserver >/dev/null 2>&1; then
  oc -n openshift-operator-lifecycle-manager patch deploy/packageserver --type=merge -p "{
    \"spec\": {
      \"replicas\": 1,
      \"strategy\": {\"type\":\"Recreate\"},
      \"template\": {\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\":\"$SURV\"}}}
    }
  }" || true
  oc -n openshift-operator-lifecycle-manager delete pod -l app=packageserver --force --grace-period=0 || true
fi

# --- Storage (cluster-storage-operator) ---
if oc -n openshift-cluster-storage-operator get deploy/cluster-storage-operator >/dev/null 2>&1; then
  oc -n openshift-cluster-storage-operator patch deploy/cluster-storage-operator --type=merge -p "{
    \"spec\": {
      \"replicas\": 1,
      \"strategy\": {\"type\":\"Recreate\"},
      \"template\": {\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\":\"$SURV\"}}}
    }
  }" || true
  oc -n openshift-cluster-storage-operator delete pod --all --force --grace-period=0 || true
fi

log "Pre step complete (degraded mode). Exiting clean."
exit 0
