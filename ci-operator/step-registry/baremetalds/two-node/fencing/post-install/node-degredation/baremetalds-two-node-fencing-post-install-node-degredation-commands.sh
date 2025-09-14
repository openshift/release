#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

echo "baremetalds-two-node-fencing-post-install-node-degradation starting..."

# ====== CONFIG / OUTPUT LOCATIONS ======
ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
echo "Artifacts will be written to: ${ART_BASE}"

FORCE_DOWNSHIFT="${FORCE_DOWNSHIFT:-true}"

log() { echo "[$(date +'%F %T%z')] $*"; }
run() { log "RUN: $*"; bash -c "$*" | tee -a "${ART_BASE}/commands.log"; }

# ====== GATE: ENV ======
if [[ -z "${DEGRADED_NODE:-}" || "${DEGRADED_NODE}" != "true" ]]; then
  log "DEGRADED_NODE not true; skipping"
  exit 0
fi

# ====== ACCESS TO HOST ======
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  log "No server IP found; skipping host SSH and exiting early."
  exit 0
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
: "${IP:?IP not set from packet-conf.sh}"
: "${SSHOPTS:?SSHOPTS not set from packet-conf.sh}"
[[ -n "${SSHOPTS[*]}" ]] || { echo "[FATAL] SSHOPTS empty"; exit 12; }

# ====== OC CLIENT ======
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[[ -f "$KUBECONFIG" ]] || { echo "[FATAL] kubeconfig missing at $KUBECONFIG"; exit 12; }

ensure_oc_mirror() {
  command -v oc >/dev/null 2>&1 && return 0
  local CLI_TAG_LOCAL="${CLI_TAG:-4.20}" UNAME_M OC_TARBALL url
  UNAME_M="$(uname -m)"
  case "$UNAME_M" in
    x86_64)        OC_TARBALL="openshift-client-linux.tar.gz" ;;
    aarch64|arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
  esac
  url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
  mkdir -p /tmp/ocbin
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 15 "$url" | tar -xz -C /tmp/ocbin oc kubectl
  else
    wget -qO- --tries=5 --timeout=15 "$url" | tar -xz -C /tmp/ocbin oc kubectl
  fi
  chmod +x /tmp/ocbin/oc /tmp/ocbin/kubectl || true
  export PATH="/tmp/ocbin:$PATH"; hash -r
  oc version --client >/dev/null 2>&1
}
ensure_oc_mirror

# ====== BASELINE SNAPSHOT ======
log "Collecting baseline cluster snapshots (pre-degradation)..."
oc whoami                                 | tee "${ART_BASE}/00_whoami.txt" || true
oc get nodes -o wide                      | tee "${ART_BASE}/00_nodes.txt"  || true
oc get co -o wide                         | tee "${ART_BASE}/00_cos.txt"    || true
oc -n openshift-image-registry get svc,image-registry,endpoints -o wide \
  | tee "${ART_BASE}/00_registry_svcs.txt" || true
oc get configs.imageregistry.operator.openshift.io/cluster -oyaml \
  | tee "${ART_BASE}/00_imageregistry_config.yaml" || true

# Survivor detection (pre-degrade)
SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
        | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
echo "$SURV" > "${ART_BASE}/00_survivor.txt"
log "Pre-degrade survivor guess: ${SURV}"

# ====== PRE-DEGRADATION PROBE (PINNED TO SURVIVOR) ======
NS_JSON=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "$SURV")

set +e
oc -n openshift-image-registry delete pod precheck --ignore-not-found
oc -n openshift-image-registry run precheck --overrides="$NS_JSON" \
  --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
  bash -lc '
    for i in $(seq 1 150); do
      date "+%F %T"
      getent hosts image-registry.openshift-image-registry.svc || true
      code="$(curl -s -o /dev/null -w "%{http_code}" -k https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)"
      case "$code" in 200|401|403) echo "OK registry HTTP:$code";; *) echo "FAIL registry HTTP:$code";; esac
      timeout 3 bash -lc '\''cat < /dev/null > /dev/tcp/image-registry.openshift-image-registry.svc/5000'\'' && echo "OK tcp" || echo "FAIL tcp"
      sleep 2
    done
  ' | tee "${ART_BASE}/01_precheck_probe.log"
oc -n openshift-image-registry delete pod precheck --wait=false --ignore-not-found
set -e

# ====== LIGHT WATCHERS (non-blocking) ======
(
  set +e
  while true; do
    echo "----- $(date +'%F %T')"
    oc -n openshift-image-registry get endpoints image-registry -o wide || true
    oc -n openshift-image-registry get deploy image-registry || true
    sleep 10
  done
) | tee "${ART_BASE}/02_watch_registry.log" &
PID_WATCH=$!

(
  set +e
  echo "=== Events (follow) ==="
  oc -n openshift-image-registry get events --sort-by=.lastTimestamp -w || true
) | tee "${ART_BASE}/03_events_registry.log" &
PID_EVENTS=$!

# ====== DEGRADE THE SECOND NODE (POWER OFF master-1 VM) ======
log "Connecting to host and shutting down ostest_master_1..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -xeo pipefail
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
  virsh -c qemu:///system shutdown ostest_master_1 || true
  for i in {1..12}; do
    [[ "$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)" == "shut off" ]] && break
    sleep 10
  done
  [[ "$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)" == "shut off" ]] || virsh -c qemu:///system destroy ostest_master_1 || true
fi
EOF

# ====== POST-DEGRADATION PROBE (PINNED TO SURVIVOR) ======
set +e
oc -n openshift-image-registry delete pod postcheck --ignore-not-found
oc -n openshift-image-registry run postcheck --overrides="$NS_JSON" \
  --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
  bash -lc '
    for i in $(seq 1 300); do
      date "+%F %T"
      getent hosts image-registry.openshift-image-registry.svc || true
      code="$(curl -s -o /dev/null -w "%{http_code}" -k https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)"
      case "$code" in 200|401|403) echo "OK registry HTTP:$code";; *) echo "FAIL registry HTTP:$code";; esac
      timeout 3 bash -lc '\''cat < /dev/null > /dev/tcp/image-registry.openshift-image-registry.svc/5000'\'' && echo "OK tcp" || echo "FAIL tcp"
      sleep 2
    done
  ' | tee "${ART_BASE}/06_postcheck_probe.log"
oc -n openshift-image-registry delete pod postcheck --wait=false --ignore-not-found
set -e

# ====== SNAPSHOTS AFTER PROBE ======
log "Capturing post-degradation snapshots..."
oc get nodes -o wide | tee "${ART_BASE}/10_nodes_post.txt" || true

# ====== OPTIONAL MITIGATION (FORCE DOWNSHIFT) ======
if [[ "${FORCE_DOWNSHIFT}" == "true" ]]; then
  log "Applying single-replica patches & tolerant rollouts"

  # Recompute survivor (exclude NotReady nodes)
  SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          | awk '$2=="True"{print $1;exit}')"
  : "${SURV:=master-0}"
  NS_JSON=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "$SURV")

  # Image Registry operator: single replica, emptyDir, pin to survivor
  run "oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{
    \"spec\": {\"managementState\":\"Managed\",\"replicas\":1,\"storage\":{\"emptyDir\":{}},
    \"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"},\"tolerations\":[]}}'"

  # Deployment strategy tolerant to marooned pod on dead node
  run "oc -n openshift-image-registry patch deploy/image-registry --type=merge -p '{
    \"spec\": {\"strategy\":{\"type\":\"Recreate\"},\"progressDeadlineSeconds\":1800,\"minReadySeconds\":0}}'"

  # Best-effort: delete any registry pod on NotReady nodes
  NNR="$(oc get nodes | awk '$2 !~ /^Ready(,|$)/ {print $1}')"
  if [[ -n "${NNR:-}" ]]; then
    for nn in $NNR; do
      pod="$(oc -n openshift-image-registry get pod -o wide 2>/dev/null | awk -v N=\"$nn\" '\$1 ~ /^image-registry-/ && \$7==N {print \$1; exit}')"
      [[ -n "${pod:-}" ]] && oc -n openshift-image-registry delete pod "$pod" --force --grace-period=0 || true
    done
  fi

  run "oc -n openshift-image-registry rollout restart deploy/image-registry"
  ( set +e
    oc -n openshift-image-registry wait --for=condition=Available deploy/image-registry --timeout=20m
    echo "RC=$?"
    oc -n openshift-image-registry get pod -o wide | awk -v N="$SURV" '$1 ~ /^image-registry-/ && $3=="Running" && $7==N {found=1} END{exit !found}'
    echo "AssertRC=$?"
    set -e
  ) | tee -a "${ART_BASE}/11_registry_rollout_status.log"

  # OCM (controller-manager) single replica (tolerant)
  OCM_DEPLOY="$(oc -n openshift-controller-manager get deploy -o name 2>/dev/null | grep controller-manager || true)"
  if [[ -n "${OCM_DEPLOY}" ]]; then
    run "oc -n openshift-controller-manager patch ${OCM_DEPLOY} --type=merge -p '{
      \"spec\": {\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
      \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}}, \"progressDeadlineSeconds\":1800}}'"
    run "oc -n openshift-controller-manager rollout restart ${OCM_DEPLOY}"
    ( set +e
      oc -n openshift-controller-manager wait --for=condition=Available "${OCM_DEPLOY}" --timeout=20m
      echo "RC=$?"
      set -e
    ) | tee -a "${ART_BASE}/11_ocm_rollout_status.log"
  fi

  # OLM packageserver single replica (pin + tolerant)
  run "oc -n openshift-operator-lifecycle-manager patch deploy/packageserver --type=merge -p '{
    \"spec\": {\"replicas\":1, \"strategy\":{\"type\":\"Recreate\"},
    \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}},
    \"progressDeadlineSeconds\":1800, \"minReadySeconds\":0}}'"

  # Delete any packageserver pod on NotReady nodes (best effort)
  if [[ -n "${NNR:-}" ]]; then
    for nn in $NNR; do
      ps="$(oc -n openshift-operator-lifecycle-manager get pod -o wide 2>/dev/null | awk -v N=\"$nn\" '\$1 ~ /^packageserver-/ && \$7==N {print \$1; exit}')"
      [[ -n "${ps:-}" ]] && oc -n openshift-operator-lifecycle-manager delete pod "$ps" --force --grace-period=0 || true
    done
  fi

  run "oc -n openshift-operator-lifecycle-manager rollout restart deploy/packageserver"
  ( set +e
    oc -n openshift-operator-lifecycle-manager wait --for=condition=Available deploy/packageserver --timeout=20m
    echo "RC=$?"
    oc -n openshift-operator-lifecycle-manager get pod -o wide | awk -v N="$SURV" '$1 ~ /^packageserver-/ && $3=="Running" && $7==N {found=1} END{exit !found}'
    echo "AssertRC=$?"
    set -e
  ) | tee -a "${ART_BASE}/11_packageserver_rollout_status.log"

  # Internal registry hostname (bounded wait)
  IRH=""
  for attempt in $(seq 1 10); do
    IRH="$(oc get image.config.openshift.io/cluster -o jsonpath='{.status.internalRegistryHostname}' 2>/dev/null || true)"
    [[ -n "${IRH}" ]] && break
    log "waiting for internalRegistryHostname (${attempt}/10)..."
    sleep 15
  done
  echo "internalRegistryHostname=${IRH:-<empty>}" | tee "${ART_BASE}/11_internal_registry_hostname.txt"
fi

# ====== FINAL SUMMARY ======
cat <<EOF | tee "${ART_BASE}/README.txt"
Artifacts for degraded two-node run:
- 00_* : Baseline
- 01_precheck_probe.log : Pre-degrade probe (pinned to survivor)
- 02_watch_registry.log, 03_events_registry.log : Lightweight watchers
- 06_postcheck_probe.log : Post-degrade probe (pinned to survivor)
- 10_* : Post snapshots
- 11_* : Mitigation patches & rollout status (if FORCE_DOWNSHIFT=true)
EOF

log "Node degradation and debug capture completed."
