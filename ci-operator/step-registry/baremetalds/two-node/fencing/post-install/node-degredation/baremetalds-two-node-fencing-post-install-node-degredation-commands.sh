#!/bin/bash
set -o nounset -o errexit -o pipefail

log(){ echo "[$(date +'%F %T%z')] $*"; }
echo "[INFO] degraded two-node fencing pre step starting..."

# ---------- config / artifacts ----------
ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"; export KUBECONFIG

# ---------- gates ----------
if [[ -z "${DEGRADED_NODE:-}" ]]; then
  log "DEGRADED_NODE is not set, skipping node degradation"; exit 0
fi
if [[ "${DEGRADED_NODE}" != "true" ]]; then
  log "DEGRADED_NODE='${DEGRADED_NODE}', not 'true' — skipping"; exit 0
fi
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  log "No server IP found; skipping node degradation"; exit 0
fi

# ---------- ensure oc ----------
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
  chmod +x /tmp/ocbin/oc || true
  export PATH="/tmp/ocbin:$PATH"; hash -r
fi
oc version --client | tee "${ART_BASE}/oc-version.txt" || true

# ---------- global timebox (110 min) ----------
GLOBAL_DEADLINE=$(( $(date +%s) + 6600 ))
must_have_time(){ local left=$((GLOBAL_DEADLINE-$(date +%s))); if [[ $left -le 60 ]]; then log "TIMEBOX_EXIT (≤60s left)"; exit 0; fi; }

# ---------- pick survivor (masters only) ----------
SURV="$(oc get nodes -l node-role.kubernetes.io/master \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
  | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
echo "$SURV" > "${ART_BASE}/survivor.txt"
log "Survivor: $SURV"

# ---------- degrade master-1 on host (keeps ostestbm) ----------
SKIP_HOST_SSH=0
if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  log "packet-conf.sh not found in SHARED_DIR; skipping host SSH actions"
  SKIP_HOST_SSH=1
fi
# shellcheck source=/dev/null
[[ $SKIP_HOST_SSH -eq 1 ]] || source "${SHARED_DIR}/packet-conf.sh"

if [[ $SKIP_HOST_SSH -eq 0 && -n "${IP:-}" ]]; then
  log "Degrading ostest_master_1 via hypervisor @ ${IP}"
  timeout -s 9 5m ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 root@"$IP" bash -s << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g' || true
set -eo pipefail
command -v virsh >/dev/null 2>&1 || { echo "[host] virsh not found, aborting host actions"; exit 0; }

echo "[host] VMs before:"
virsh -c qemu:///system list --all || true

echo "[host] Attempting graceful shutdown of ostest_master_1..."
virsh -c qemu:///system shutdown ostest_master_1 || true
for i in {1..12}; do
  st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)
  [[ "$st" == "shut off" ]] && break
  sleep 10
done
st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)
[[ "$st" == "shut off" ]] || virsh -c qemu:///system destroy ostest_master_1 || true

echo "[host] VMs after:"
virsh -c qemu:///system list --all || true

# Network name intentionally fixed: ostestbm
echo "[host] DHCP leases (ostestbm):"
virsh -c qemu:///system net-dhcp-leases ostestbm || true
MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm 2>/dev/null | awk '/master-0/ {print $5}' | cut -d/ -f1 | head -n1)

# Best-effort pcs on master-0 (bounded)
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
  log "Host SSH not attempted (no packet-conf.sh or IP empty)"
fi

# ---------- probe helper (pinned; no hangs) ----------
PROBE_NS="openshift-image-registry"
oc get ns "$PROBE_NS" >/dev/null 2>&1 || PROBE_NS="openshift-operators"

probe_pod(){
  local name=$1 dur=$2
  must_have_time
  local nsjson; nsjson=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "$SURV")

  oc -n "$PROBE_NS" delete pod "$name" --ignore-not-found --wait=false || true
  oc -n "$PROBE_NS" run "$name" --image=curlimages/curl:8.9.1 \
    --image-pull-policy=IfNotPresent --restart=Never --overrides="$nsjson" -- \
    sh -lc "
      set -eu
      end=\$((\$(date +%s) + ${dur}*2))
      while [ \$(date +%s) -lt \$end ]; do
        date '+%F %T'
        code=\$(curl -sk -o /dev/null -w '%{http_code}' https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)
        echo REGISTRY:\$code
        sleep 2
      done
    " >/dev/null 2>&1 || true
  timeout 30s oc -n "$PROBE_NS" logs "pod/$name" --tail=200 | tee "${ART_BASE}/${name}.log" || true
  oc -n "$PROBE_NS" delete pod "$name" --ignore-not-found --wait=false || true
}

# ---------- probes (bounded) ----------
probe_pod precheck 150
probe_pod postcheck 300

# ---------- registry: guard + force single replica on survivor ----------
must_have_time
mgmt="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "")"
if [[ "$mgmt" == "Removed" ]]; then
  log "Image Registry managementState=Removed; skipping registry pin/scale."
else
  log "Forcing registry single replica on ${SURV} with emptyDir storage (clearing PVC/others)"
  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p "{
    \"spec\": {
      \"replicas\": 1,
      \"managementState\": \"Managed\",
      \"nodeSelector\": {\"kubernetes.io/hostname\":\"${SURV}\"},
      \"tolerations\": [],
      \"storage\": {
        \"emptyDir\": {},
        \"pvc\": null,
        \"s3\": null, \"gcs\": null, \"azure\": null, \"swift\": null, \"ibmcos\": null
      }
    }
  }" || true

  oc -n openshift-image-registry patch deploy/image-registry --type=merge -p "{
    \"spec\": {
      \"replicas\": 1,
      \"strategy\": {\"type\": \"Recreate\", \"rollingUpdate\": null},
      \"template\": {\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\": \"${SURV}\"}}}
    }
  }" || true

  # delete any registry pod marooned on NotReady nodes (no awk-quote)
  NNR="$(oc get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$NNR" ]]; then
  # Fallback: derive from full conditions line; avoid quote-escape issues
    NNR="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}{"="}{.status}{";"}{end}{"\n"}{end}' \
          | awk '!/Ready=True/ {print $1}')"
  fi
  for nn in $NNR; do
    pod="$(oc -n openshift-image-registry get pod -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' 2>/dev/null \
           | awk -v N=\"$nn\" '$2==N && $1 ~ /^image-registry-/{print $1;exit}')"
    [[ -n "${pod:-}" ]] && oc -n openshift-image-registry delete pod "$pod" --force --grace-period=0 || true
  done

  # bounded readiness: ≤ 20m, success = exactly 1 Running registry pod on SURV, none elsewhere
  deadline=$(( $(date +%s) + 1200 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    must_have_time
    if oc -n openshift-image-registry get pod -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.nodeName}{"\n"}{end}' 2>/dev/null \
       | awk -v N="$SURV" '
         /^image-registry-/{
           if ($2=="Running"){running[$3]++}
         }
         END{
           ok=(running[N]==1)
           for(n in running) if(n!=N && running[n]>0) ok=0
           exit !ok
         }'
    then
      log "Registry stable: 1 Running pod on ${SURV}"
      break
    fi
    sleep 10
  done
fi

# ---------- pin OCM/OLM/CSO (Recreate, bounded) ----------
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
