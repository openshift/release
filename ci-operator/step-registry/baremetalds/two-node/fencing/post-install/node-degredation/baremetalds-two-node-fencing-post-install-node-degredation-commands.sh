#!/bin/bash
set -o nounset -o errexit -o pipefail

# ---------- logging ----------
log(){ echo "[$(date +'%F %T%z')] $*"; }
echo "[INFO] degraded two-node fencing pre step starting..."

# ---------- config / artifacts ----------
ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"; export KUBECONFIG

# ---------- gates from legacy script ----------
if [[ -z "${DEGRADED_NODE:-}" ]]; then
  log "DEGRADED_NODE is not set, skipping node degradation"; exit 0
fi
if [[ "${DEGRADED_NODE}" != "true" ]]; then
  log "DEGRADED_NODE='${DEGRADED_NODE}', not 'true' — skipping"; exit 0
fi
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  log "No server IP found; skipping node degradation"; exit 0
fi

# ---------- ensure oc present (self-contained, no root needed) ----------
if ! command -v oc >/dev/null 2>&1; then
  log "oc not found, installing client..."
  CLI_TAG_LOCAL="${CLI_TAG:-4.20}"
  UNAME_M="$(uname -m)"
  case "$UNAME_M" in
    x86_64) OC_TARBALL="openshift-client-linux.tar.gz" ;;
    aarch64|arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
    *) log "Unsupported arch: $UNAME_M"; exit 1 ;;
  esac
  url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
  mkdir -p /tmp/ocbin
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
  else wget -qO- "$url" | tar -xz -C /tmp/ocbin oc; fi
  chmod +x /tmp/ocbin/oc || true; export PATH="/tmp/ocbin:$PATH"; hash -r
fi

# ---------- global timebox (110 min) ----------
GLOBAL_DEADLINE=$(( $(date +%s) + 6600 ))
must_have_time(){ [[ $((GLOBAL_DEADLINE-$(date +%s))) -gt 60 ]] || { log "Timebox hit, exiting cleanly."; exit 0; }; }

# ---------- pick survivor ----------
SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
echo "$SURV" > "${ART_BASE}/survivor.txt"
log "Survivor: $SURV"

# ---------- degrade master-1 on host (timeout + safe) ----------
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
if [[ -n "${IP:-}" ]]; then
  log "Degrading ostest_master_1 via hypervisor @ ${IP}"
  timeout -s 9 5m ssh -o StrictHostKeyChecking=no root@"$IP" bash -s << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g' || true
set -eo pipefail
echo "[host] VMs before:"
virsh -c qemu:///system list --all || true
echo "[host] Attempting graceful shutdown of ostest_master_1..."
virsh -c qemu:///system shutdown ostest_master_1 || true
for i in {1..12}; do st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true); [[ "$st" == "shut off" ]] && break; sleep 10; done
st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)
[[ "$st" == "shut off" ]] || virsh -c qemu:///system destroy ostest_master_1 || true
echo "[host] VMs after:"
virsh -c qemu:///system list --all || true

# Optional: run pcs on master-0 (best-effort, bounded)
echo "[host] DHCP leases:"
virsh -c qemu:///system net-dhcp-leases ostestbm || true
MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm 2>/dev/null | awk '/master-0/ {print $5}' | cut -d/ -f1 | head -n1)
if [[ -n "${MASTER0_IP:-}" ]]; then
  timeout 90s ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 core@"${MASTER0_IP}" << 'PCS_EOF' || true
sudo pcs resource status || true
sudo pcs property set stonith-enabled=false || true
sudo pcs resource cleanup etcd || true
sudo pcs resource status || true
PCS_EOF
fi
EOF
else
  log "IP from packet-conf.sh is empty; skipping host SSH"
fi

# ---------- probe helper (pinned to survivor) ----------
probe_pod(){
  local name=$1 dur=$2
  must_have_time
  local nsjson; nsjson=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "$SURV")
  oc -n openshift-image-registry delete pod "$name" --ignore-not-found --wait=false
  oc -n openshift-image-registry run "$name" --overrides="$nsjson" \
    --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
    bash -lc "
      for i in \$(seq 1 $dur); do
        date '+%F %T'
        getent hosts image-registry.openshift-image-registry.svc || true
        code=\$(curl -sk -o /dev/null -w '%{http_code}' https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)
        echo REGISTRY:\$code
        sleep 2
      done" | tee "${ART_BASE}/${name}.log"
  oc -n openshift-image-registry delete pod "$name" --ignore-not-found --wait=false
}

# ---------- probes (bounded, no waits after delete) ----------
probe_pod precheck 150
probe_pod postcheck 300

# ---------- registry: force and keep single replica on survivor ----------
must_have_time
log "Forcing registry single replica on ${SURV}"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p "{
  \"spec\": {\"replicas\":1, \"managementState\":\"Managed\",
            \"nodeSelector\": {\"kubernetes.io/hostname\":\"${SURV}\"},
            \"tolerations\":[], \"storage\":{\"emptyDir\":{}}}
}" || true

oc -n openshift-image-registry patch deploy/image-registry --type=merge -p "{
  \"spec\": {\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
            \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"},
                                   \"affinity\":null, \"topologySpreadConstraints\":null}}}
}" || true

# delete any registry pod marooned on NotReady node
NNR="$(oc get nodes 2>/dev/null | awk '$2!=\"Ready\"{print $1}')"
for nn in $NNR; do
  pod="$(oc -n openshift-image-registry get pod -o wide 2>/dev/null | awk -v N=\"$nn\" '$1 ~ /^image-registry-/ && $7==N {print $1;exit}')"
  [[ -n "${pod:-}" ]] && oc -n openshift-image-registry delete pod "$pod" --force --grace-period=0 || true
done

# bounded readiness: <= 20m, success = exactly 1 Running registry pod on SURV, none on others
deadline=$(( $(date +%s) + 500 ))
while [[ $(date +%s) -lt $deadline ]]; do
  must_have_time
  if oc -n openshift-image-registry get pod -o wide 2>/dev/null \
     | awk -v N="$SURV" '$1~/^image-registry-/ && $3=="Running"{running[$7]++}
       END{ok=(running[N]==1); for(n in running) if(n!=N && running[n]>0) ok=0; exit !ok}'; then
    log "Registry stable: 1 Running pod on ${SURV}"
    break
  fi
  sleep 10
done

# ---------- force scale-down+pin of OCM/OLM/Storage (Recreate) ----------
if oc -n openshift-controller-manager get deploy/controller-manager >/dev/null 2>&1; then
  oc -n openshift-controller-manager patch deploy/controller-manager --type=merge -p "{
    \"spec\":{\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
      \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}}}
  }" || true
  oc -n openshift-controller-manager delete pod -l app=openshift-controller-manager --force --grace-period=0 || true
fi

if oc -n openshift-operator-lifecycle-manager get deploy/packageserver >/dev/null 2>&1; then
  oc -n openshift-operator-lifecycle-manager patch deploy/packageserver --type=merge -p "{
    \"spec\":{\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
      \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}}}
  }" || true
  oc -n openshift-operator-lifecycle-manager delete pod -l app=packageserver --force --grace-period=0 || true
fi

if oc -n openshift-cluster-storage-operator get deploy/cluster-storage-operator >/dev/null 2>&1; then
  oc -n openshift-cluster-storage-operator patch deploy/cluster-storage-operator --type=merge -p "{
    \"spec\":{\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
      \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}}}
  }" || true
  oc -n openshift-cluster-storage-operator delete pod --all --force --grace-period=0 || true
fi

log "Pre step complete (degraded mode). Exiting clean."
exit 0
