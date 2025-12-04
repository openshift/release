#!/bin/bash
set -o nounset -o errexit -o pipefail

# Variables
PROBE_NS="openshift-image-registry"               # fallback to operators later if missing
GLOBAL_DEADLINE=$(( $(date +%s) + 1200 ))         # 20 minutes global timebox
SURV=""                                           # will be detected
SKIP_HOST_SSH=0

# Logging
log() {
  echo "[$(date +'%F %T%z')] $*"
}

echo "[INFO] degraded two-node fencing pre step starting..."

# Guards
if [[ "${DEGRADED_NODE:-}" != "true" ]]; then
  log "DEGRADED_NODE='${DEGRADED_NODE:-}' (not 'true') — skipping"
  exit 0
fi

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  log "No server IP found; skipping node degradation"
  exit 0
fi

# Helpers
must_have_time() {
  local now left
  now=$(date +%s)
  left=$(( GLOBAL_DEADLINE - now ))
  if [[ ${left} -le 60 ]]; then
    log "TIMEBOX_EXIT (≤60s left)"
    exit 0
  fi
}

pin_single_replica_recreate() {
  local ns="$1" dep="$2" dels="${3:-}"
  must_have_time

  if oc -n "${ns}" get deploy "${dep}" >/dev/null 2>&1; then
    oc -n "${ns}" patch deploy/"${dep}" --type=merge -p "{
      \"spec\":{
        \"replicas\":1,
        \"strategy\":{\"type\":\"Recreate\"},
        \"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SURV}\"}}}
      }
    }" || true

    if [[ -n "${dels}" ]]; then
      oc -n "${ns}" delete pod -l "${dels}" --force --grace-period=0 || true
    else
      oc -n "${ns}" delete pod --all --force --grace-period=0 || true
    fi
  fi
}

# Survivor node detection
SURV="$(oc get nodes -l node-role.kubernetes.io/master \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
  | awk '$2=="True"{print $1;exit}')"
: "${SURV:=master-0}"
log "Survivor: ${SURV}"

# Host SSH setup (optional)
if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  log "packet-conf.sh not found in SHARED_DIR; skipping host SSH actions"
  SKIP_HOST_SSH=1
else
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/packet-conf.sh"
fi

# Degrade master-1 via hypervisor
if [[ ${SKIP_HOST_SSH} -eq 0 && -n "${IP:-}" ]]; then
  log "Degrading ostest_master_1 via hypervisor @ ${IP}"
  timeout -s 9 5m ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
    root@"${IP}" bash -s << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g' || true
set -euo pipefail

if ! command -v virsh >/dev/null 2>&1; then
  echo "[host] virsh not found, aborting host actions"
  exit 0
fi

# Network name intentionally fixed
NET="ostestbm"

echo "[host] DHCP leases (${NET}):"
virsh -c qemu:///system net-dhcp-leases "${NET}" || true

MASTER0_IP="$(virsh -c qemu:///system net-dhcp-leases "${NET}" 2>/dev/null | awk '/master-0/ {print $5}' | cut -d/ -f1 | head -n1)"

# pcs actions on master-0 *before* shutting down master-1
if [[ -n "${MASTER0_IP:-}" ]]; then
  timeout 90s ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
    core@"${MASTER0_IP}" << 'PCS_EOF' || true
sudo pcs status || true
sudo pcs resource debug-stop etcd || true
sudo pcs resource status || true
PCS_EOF
fi

echo "[host] VMs before:"
virsh -c qemu:///system list --all || true

echo "[host] Attempting graceful shutdown of ostest_master_1..."
virsh -c qemu:///system shutdown ostest_master_1 || true

for i in {1..12}; do
  st="$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)"
  [[ "${st}" == "shut off" ]] && break
  sleep 10
done

st="$(virsh -c qemu:///system domstate ostest_master_1 2>/dev/null || true)"
[[ "${st}" == "shut off" ]] || virsh -c qemu:///system destroy ostest_master_1 || true

echo "[host] VMs after:"
virsh -c qemu:///system list --all || true
EOF
else
  log "Host SSH not attempted (no packet-conf.sh or IP empty)"
fi


# WORKAROUND for OCPBUGS-63312 (keep while bug is unresolved)

# Decide probe namespace (fallback if IR ns missing)
if ! oc get ns "${PROBE_NS}" >/dev/null 2>&1; then
  PROBE_NS="openshift-operators"
fi

probe_pod() {
  # $1 name, $2 duration(sec)
  local name="$1" dur="$2"
  must_have_time

  local node_selector_json
  node_selector_json=$(printf '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"}}}' "${SURV}")

  oc -n "${PROBE_NS}" delete pod "${name}" --ignore-not-found --wait=false || true

  oc -n "${PROBE_NS}" run "${name}" \
    --image=curlimages/curl:8.9.1 \
    --image-pull-policy=IfNotPresent \
    --restart=Never \
    --overrides="${node_selector_json}" \
    -- sh -lc "
      set -eu
      end=\$((\$(date +%s) + ${dur}*2))
      while [ \$(date +%s) -lt \"\${end}\" ]; do
        date '+%F %T'
        code=\$(curl -sk -o /dev/null -w '%{http_code}' https://image-registry.openshift-image-registry.svc:5000/v2/ || echo 000)
        echo REGISTRY:\${code}
        sleep 2
      done
    " >/dev/null 2>&1 || true

  timeout 30s oc -n "${PROBE_NS}" logs "pod/${name}" --tail=200 || true
  oc -n "${PROBE_NS}" delete pod "${name}" --ignore-not-found --wait=false || true
}

# Bounded probes
probe_pod precheck 150
probe_pod postcheck 300

# Image Registry pin/scale
must_have_time

mgmt="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || echo "")"
if [[ "${mgmt}" == "Removed" ]]; then
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

  # Delete any registry pod marooned on NotReady nodes
  NOT_READY_NODES="$(
    oc get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  )"
  if [[ -z "${NOT_READY_NODES}" ]]; then
    NOT_READY_NODES="$(
      oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}{"="}{.status}{";"}{end}{"\n"}{end}' \
      | awk '!/Ready=True/ {print $1}'
    )"
  fi

  for nn in ${NOT_READY_NODES}; do
    pod="$(
      oc -n openshift-image-registry get pod -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' 2>/dev/null \
      | awk -v N="${nn}" '$2==N && $1 ~ /^image-registry-/{print $1;exit}'
    )"
    if [[ -n "${pod:-}" ]]; then
      oc -n openshift-image-registry delete pod "${pod}" --force --grace-period=0 || true
    fi
  done

  # Bounded readiness: success when exactly 1 Running registry pod on SURV, none elsewhere
  deadline=$(( $(date +%s) + 1200 ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    must_have_time
    if oc -n openshift-image-registry get pod -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.nodeName}{"\n"}{end}' 2>/dev/null \
      | awk -v N="${SURV}" '
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

# Pin OCM / OLM / CSO
pin_single_replica_recreate "openshift-controller-manager" "controller-manager" "app=openshift-controller-manager"
pin_single_replica_recreate "openshift-operator-lifecycle-manager" "packageserver" "app=packageserver"
pin_single_replica_recreate "openshift-cluster-storage-operator" "cluster-storage-operator"

log "Pre step complete (degraded mode). Exiting clean."
exit 0
