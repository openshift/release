#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

# ====== CONFIG / OUTPUT LOCATIONS ======
ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
echo "Artifacts will be written to: ${ART_BASE}"

# Toggle: capture-only vs. force downshift of selected operands
# - false: DO NOT scale/patch registry/OCM/OLM (debug only, recommended to reproduce)
# - true:  Apply single-replica & rollout nudges after degradation (stabilize run)
FORCE_DOWNSHIFT="${FORCE_DOWNSHIFT:-false}"
echo "FORCE_DOWNSHIFT=${FORCE_DOWNSHIFT}"

# ====== HELPERS ======
log() { echo "[$(date +'%F %T%z')] $*"; }
run() { log "RUN: $*"; bash -c "$*" | tee -a "${ART_BASE}/commands.log"; }

# ====== GATE: ENV ======
if [[ -z "${DEGRADED_NODE:-}" ]]; then
  log "DEGRADED_NODE is not set, skipping node degradation"
  exit 0
fi
if [[ "${DEGRADED_NODE}" != "true" ]]; then
  log "DEGRADED_NODE is '${DEGRADED_NODE}', not 'true' - skipping"
  exit 0
fi

# ====== ACCESS TO HOST ======
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  log "No server IP found; skipping host SSH and exiting early."
  exit 0
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# ====== BASELINE SNAPSHOT (before degradation, before any scaling) ======
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

log "Collecting baseline cluster snapshots (pre-degradation)..."
oc whoami            | tee "${ART_BASE}/00_whoami.txt" || true
oc get nodes -o wide | tee "${ART_BASE}/00_nodes.txt"  || true
oc get co -o wide    | tee "${ART_BASE}/00_cos.txt"    || true

oc -n openshift-image-registry get svc image-registry -o wide \
  | tee "${ART_BASE}/00_registry_svc.txt" || true
oc -n openshift-image-registry get endpoints image-registry -o yaml \
  | tee "${ART_BASE}/00_registry_endpoints.yaml" || true
oc -n openshift-image-registry get deploy/image-registry -oyaml \
  | tee "${ART_BASE}/00_registry_deploy.yaml" || true
oc get configs.imageregistry.operator.openshift.io/cluster -oyaml \
  | tee "${ART_BASE}/00_imageregistry_config.yaml" || true

# Detect survivor & not-ready nodes now (pre-degrade view)
SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
        | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
NOTREADY_NODES="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
        | awk '$2!="True"{print $1}')"
log "Pre-degrade survivor guess: ${SURV}"
log "Pre-degrade NotReady nodes: ${NOTREADY_NODES:-<none>}"
printf '%s\n' "${SURV}" > "${ART_BASE}/00_survivor.txt"

# ====== PRE-DEGRADATION AVAILABILITY PROBE (no scaling) ======
log "Starting 5-minute pre-degradation availability probe from an in-cluster pod..."
set +e
oc -n openshift-image-registry run precheck --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- bash -lc \
  'for i in $(seq 1 150); do date "+%F %T"; getent hosts image-registry.openshift-image-registry.svc || true; curl -sS -k https://image-registry.openshift-image-registry.svc:5000/v2/ || echo FAIL; sleep 2; done' \
  | tee "${ART_BASE}/01_precheck_probe.log"
set -e

# ====== CONTINUOUS WATCHERS (background) ======
log "Starting background watchers (endpoints/deploy/pods/events/operator logs)..."
(
  set +e
  while true; do
    echo "----- $(date +'%F %T')"
    oc -n openshift-image-registry get endpoints image-registry -o wide
    oc -n openshift-image-registry get deploy image-registry
    oc -n openshift-image-registry get pods -o wide
    sleep 10
  done
) | tee "${ART_BASE}/02_watch_ep_deploy_pods.log" &
PID_WATCH=$!

(
  set +e
  oc -n openshift-image-registry logs deploy/cluster-image-registry-operator --since=1h -f
) | tee "${ART_BASE}/03_operator.log" &
PID_OPLOG=$!

(
  set +e
  echo "=== Describe deploy once ==="
  oc -n openshift-image-registry describe deploy/image-registry
  echo "=== Events (follow) ==="
  oc -n openshift-image-registry get events --sort-by=.lastTimestamp -w
) | tee "${ART_BASE}/04_events_deploy.log" &
PID_EVENTS=$!

(
  set +e
  while true; do
    echo "----- $(date +'%F %T')"
    oc -n openshift-image-registry get pvc -o wide || true
    oc get pv | egrep 'image|registry' || true
    sleep 30
  done
) | tee "${ART_BASE}/05_storage_watch.log" &
PID_STORAGE=$!

# ====== DEGRADE THE SECOND NODE ======
log "Connecting to host and shutting down ostest_master_1..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -xeo pipefail
echo "Host VM list:"
virsh -c qemu:///system list --all

echo "Attempting graceful shutdown of ostest_master_1..."
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
  virsh -c qemu:///system shutdown ostest_master_1 || true
  # Fallback to hard stop if still running after ~120s
  for i in {1..12}; do
    st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)
    [[ "$st" == "shut off" ]] && break
    sleep 10
  done
  st=$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)
  if [[ "$st" != "shut off" ]]; then
    echo "Forcing destroy of ostest_master_1"
    virsh -c qemu:///system destroy ostest_master_1 || true
  fi
else
  echo "WARNING: ostest_master_1 not found"
fi

echo "VMs after degradation:"
virsh -c qemu:///system list --all
EOF

# Optional: cluster-side pacemaker actions (left as-is from your script)
if [[ -n "${MASTER0_IP:-}" ]]; then :; fi # placeholder if you keep pcs steps elsewhere

# ====== POST-DEGRADATION AVAILABILITY PROBE (no scaling yet) ======
log "Starting 10-minute post-degradation availability probe (do not scale during this window)..."
set +e
oc -n openshift-image-registry run postcheck --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal -- bash -lc \
  'for i in $(seq 1 300); do date "+%F %T"; getent hosts image-registry.openshift-image-registry.svc || true; curl -sS -k https://image-registry.openshift-image-registry.svc:5000/v2/ || echo FAIL; sleep 2; done' \
  | tee "${ART_BASE}/06_postcheck_probe.log"
set -e

# ====== SNAPSHOTS AFTER PROBE WINDOW ======
log "Capturing post-degradation snapshots..."
oc get nodes -o wide                                 | tee "${ART_BASE}/10_nodes_post.txt"  || true
oc get co image-registry -o yaml                     | tee "${ART_BASE}/10_co_image_registry.yaml" || true
oc -n openshift-image-registry get deploy/image-registry -oyaml \
  | tee "${ART_BASE}/10_registry_deploy_post.yaml" || true
oc -n openshift-image-registry get pods -o wide      | tee "${ART_BASE}/10_registry_pods_post.txt" || true
oc -n openshift-image-registry get endpoints image-registry -o yaml \
  | tee "${ART_BASE}/10_registry_endpoints_post.yaml" || true
oc -n openshift-image-registry logs -l docker-registry=default --since=30m --all-containers=true \
  | tee "${ART_BASE}/10_registry_pod_logs_post.log" || true

# ====== OPTIONAL MITIGATION (force downshift) ======
if [[ "${FORCE_DOWNSHIFT}" == "true" ]]; then
  log "FORCE_DOWNSHIFT=true -> applying single-replica patches & rollout nudges"

  # Recompute survivor/NotReady after degradation
  SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          | awk '$2=="True"{print $1;exit}')"
  : "${SURV:=master-0}"
  NOTREADY_NODES="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          | awk '$2!="True"{print $1}')"
  echo "${SURV}" > "${ART_BASE}/11_survivor_post.txt"

  # Image Registry: operator-level patch to single replica + emptyDir + pin to survivor
  run "oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{
    \"spec\": {\"managementState\":\"Managed\", \"replicas\":1, \"storage\": {\"emptyDir\":{}},
               \"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}, \"tolerations\":[]}}'"

  # Force-delete any stale registry pod on NotReady nodes to unblock rollout
  if [[ -n "${NOTREADY_NODES}" ]]; then
    for nn in ${NOTREADY_NODES}; do
      OLDPOD="$(oc -n openshift-image-registry get pod -o wide 2>/dev/null \
        | awk -v N=\"$nn\" '$1 ~ /^image-registry-/ && $7==N {print $1; exit}')"
      if [[ -n "${OLDPOD:-}" ]]; then
        run "oc -n openshift-image-registry delete pod '${OLDPOD}' --grace-period=0 --force"
      fi
    done
  fi
  run "oc -n openshift-image-registry scale   deploy/image-registry --replicas=1"
  run "oc -n openshift-image-registry rollout restart deploy/image-registry"
  ( set +e; oc -n openshift-image-registry rollout status deploy/image-registry --timeout=12m; echo RC=$?; set -e ) \
    | tee -a "${ART_BASE}/11_registry_rollout_status.log"

  # Wait for IRH (for OCM/tests)
  IRH=""
  for attempt in $(seq 1 20); do
    IRH="$(oc get image.config.openshift.io/cluster -o jsonpath='{.status.internalRegistryHostname}' 2>/dev/null || true)"
    [[ -n "${IRH}" ]] && break
    log "waiting for internalRegistryHostname (${attempt}/20)..."
    sleep 30
  done
  echo "internalRegistryHostname=${IRH:-<empty>}" | tee "${ART_BASE}/11_internal_registry_hostname.txt"

  # OCM operand single replica (operator stays running)
  OCM_DEPLOY="$(oc -n openshift-controller-manager get deploy -o name 2>/dev/null | grep controller-manager || true)"
  if [[ -n "${OCM_DEPLOY}" ]]; then
    run "oc -n openshift-controller-manager scale '${OCM_DEPLOY}' --replicas=1"
    run "oc -n openshift-controller-manager rollout restart '${OCM_DEPLOY}'"
    ( set +e; oc -n openshift-controller-manager rollout status "${OCM_DEPLOY}" --timeout=20m; echo RC=$?; set -e ) \
      | tee -a "${ART_BASE}/11_ocm_rollout_status.log"
  fi

  # OLM packageserver: scale/pin to survivor (tolerations left empty intentionally)
  run "oc -n openshift-operator-lifecycle-manager patch deploy/packageserver --type=merge -p '{
    \"spec\": {\"replicas\":1, \"template\": {\"spec\": {\"nodeSelector\": {\"kubernetes.io/hostname\":\"${SURV}\"}, \"tolerations\":[]}}}}'"
  run "oc -n openshift-operator-lifecycle-manager rollout restart deploy/packageserver"
  ( set +e; oc -n openshift-operator-lifecycle-manager rollout status deploy/packageserver --timeout=10m; echo RC=$?; set -e ) \
    | tee -a "${ART_BASE}/11_packageserver_rollout_status.log"
fi

# ====== CLEANUP WATCHERS ======
log "Stopping background watchers..."
kill "${PID_WATCH}"   2>/dev/null || true
kill "${PID_OPLOG}"   2>/dev/null || true
kill "${PID_EVENTS}"  2>/dev/null || true
kill "${PID_STORAGE}" 2>/dev/null || true

# ====== FINAL SUMMARY POINTERS ======
cat <<EOF | tee "${ART_BASE}/README.txt"
Artifacts captured for degraded two-node run:

- ${ART_BASE}/00_*           : Baseline (pre-degradation) state
- ${ART_BASE}/01_precheck_probe.log : 5-min pre-degrade registry availability probe
- ${ART_BASE}/02_watch_ep_deploy_pods.log : Continuous watch of endpoints/deploy/pods
- ${ART_BASE}/03_operator.log : cluster-image-registry-operator logs (follow)
- ${ART_BASE}/04_events_deploy.log : Deployment describe + live events
- ${ART_BASE}/05_storage_watch.log : PVC/PV watch (if applicable)
- ${ART_BASE}/06_postcheck_probe.log : 10-min post-degrade availability probe

If FORCE_DOWNSHIFT=true (mitigations applied):
- ${ART_BASE}/11_* : Patches, rollout statuses, and IRH
- ${ART_BASE}/10_* : Post-degradation snapshots

EOF

log "Node degradation and debug capture completed. See ${ART_BASE}/README.txt"
