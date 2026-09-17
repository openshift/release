#!/bin/bash
set -o nounset -o errexit -o

# Variables
GLOBAL_DEADLINE=$(( $(date +%s) + 1800 ))         # 30 minutes: registry wait + ACPI + API recovery
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

wait_for_image_registry_stable() {
  local deadline=$(( "$(date +%s)" + 900 ))
  local stable_required=10
  local stable_count=0

  log "Waiting for image-registry ClusterOperator to stop Progressing (need ${stable_required} consecutive False)..."

  while [[ "$(date +%s)" -lt ${deadline} ]]; do
    must_have_time

    local progressing
    progressing="$(oc get co image-registry -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "")"

    if [[ "${progressing}" == "False" ]]; then
      stable_count=$((stable_count + 1))
      log "image-registry Progressing=False (${stable_count}/${stable_required} consecutive)"
      if [[ ${stable_count} -ge ${stable_required} ]]; then
        log "image-registry ClusterOperator considered stable (Progressing=False for ${stable_required} consecutive checks)."
        return 0
      fi
    else
      if [[ -n "${progressing}" ]]; then
        log "image-registry Progressing is '${progressing}' (resetting stable counter)."
      else
        log "image-registry Progressing status unavailable (resetting stable counter)."
      fi
      stable_count=0
    fi

    sleep 10
  done

  log "image-registry did not stay non-Progressing long enough before timeout (continuing anyway)."
  return 0
}


wait_for_api_after_degradation() {
  local deadline=$(( "$(date +%s)" + 600 ))
  if [[ ${GLOBAL_DEADLINE} -lt ${deadline} ]]; then
    deadline=${GLOBAL_DEADLINE}
  fi
  local stable_required=5
  local stable_count=0

  log "Waiting for API after node degradation (need ${stable_required} consecutive /healthz ok)..."

  while [[ "$(date +%s)" -lt ${deadline} ]]; do
    if oc get --raw=/healthz --request-timeout=10s >/dev/null 2>&1; then
      stable_count=$((stable_count + 1))
      log "API /healthz ok (${stable_count}/${stable_required} consecutive)"
      if [[ ${stable_count} -ge ${stable_required} ]]; then
        log "API considered recovered after node degradation."
        return 0
      fi
    else
      log "API /healthz not ready (resetting stable counter)."
      stable_count=0
    fi

    sleep 10
  done

  log "ERROR: API did not recover after degrading node"
  return 1
}

# TODO(OCPBUGS-111074): temporary until the node-lifecycle carry is in the
# payload (False->Unknown MarkPodsNotReady and
# seeding nodeHealthMap before pod workers). Remove taint_shutdown_node_out_of_service
# and wait_for_dns_default_ready_only_on_survivor once that fix ships.
taint_shutdown_node_out_of_service() {
  local node="master-1"
  log "Tainting shutdown node ${node} with node.kubernetes.io/out-of-service=nodeshutdown:NoExecute"
  oc adm taint nodes "${node}" "node.kubernetes.io/out-of-service=nodeshutdown:NoExecute" --overwrite --request-timeout=10s
}

# Success when dns-default is ready on surviving master-0 and not ready (or
# absent) on ACPI'd master-1.
wait_for_dns_default_ready_only_on_survivor() {
  local deadline=$(( "$(date +%s)" + 300 ))
  if [[ ${GLOBAL_DEADLINE} -lt ${deadline} ]]; then
    deadline=${GLOBAL_DEADLINE}
  fi

  log "Waiting for dns-default EndpointSlice ready on master-0 and not ready on master-1..."

  while [[ "$(date +%s)" -lt ${deadline} ]]; do
    local out
    out="$(oc get endpointslices -n openshift-dns -l kubernetes.io/service-name=dns-default \
      -o jsonpath='{range .items[*].endpoints[*]}{.nodeName}{"\t"}{.conditions.ready}{"\n"}{end}' \
      --request-timeout=10s 2>/dev/null || true)"
    log "dns-default EndpointSlice backends:"$'\n'"${out:-<empty>}"

    if [[ -z "${out}" ]]; then
      log "dns-default EndpointSlice listing empty or unavailable; retrying..."
      sleep 10
      continue
    fi

    local master0_ready=0 master1_ready=0 node ready
    while IFS=$'\t' read -r node ready; do
      [[ -z "${node}" ]] && continue
      case "${ready}" in
        false|False) continue ;;
      esac
      case "${node}" in
        master-0) master0_ready=1 ;;
        master-1) master1_ready=1 ;;
      esac
    done <<< "${out}"

    if [[ ${master0_ready} -eq 1 && ${master1_ready} -eq 0 ]]; then
      log "dns-default EndpointSlice ready on master-0 only (master-1 not ready or absent)."
      return 0
    fi

    log "dns-default not yet ready-only-on-survivor (master-0 ready=${master0_ready} master-1 ready=${master1_ready}); retrying..."
    sleep 10
  done

  log "ERROR: dns-default EndpointSlice did not become ready on master-0 and not ready on master-1"
  return 1
}


wait_for_image_registry_stable

# Host SSH setup (optional)
SKIP_HOST_SSH="${SKIP_HOST_SSH:-0}"

if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  log "packet-conf.sh not found in SHARED_DIR; skipping host SSH actions"
  SKIP_HOST_SSH=1
else
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/packet-conf.sh"
fi

# Degrade master-1 via hypervisor
if [[ ${SKIP_HOST_SSH} -eq 0 && -n "${IP:-}" ]]; then
  log "Degrading master_1 via hypervisor @ ${IP}"

  set +e
  timeout -s 9 5m ssh "${SSHOPTS[@]}" root@"${IP}" bash -s << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -euo pipefail

if ! command -v virsh >/dev/null 2>&1; then
  echo "[host] virsh not found, aborting host actions"
  exit 0
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
  ssh_rc=${PIPESTATUS[0]}
  set -e

  if [[ ${ssh_rc} -ne 0 ]]; then
    log "ERROR: Failed to degrade master_1 via hypervisor (rc=${ssh_rc})"
    exit ${ssh_rc}
  fi

  # Leave etcd on the survivor alone. pcs debug-stop/debug-start recycles
  # kube-apiserver and kube-controller-manager (lease renew fails, process
  # exits) and races node-lifecycle MarkPodsNotReady. Quorum recovery after
  # the peer is OFFLINE is the etcd resource agent's job.
  wait_for_api_after_degradation

  # TODO(OCPBUGS-111074): temporary until the node-lifecycle carry is in the
  # payload (False->Unknown MarkPodsNotReady and
  # seeding nodeHealthMap before pod workers). ACPI never emits STONITH, so
  # TNF does not apply out-of-service itself; without that taint, dns-default
  # on the dead node can stay Ready and keep a zombie EndpointSlice backend.
  # Remove this taint and the EndpointSlice wait once that fix ships.
  taint_shutdown_node_out_of_service
  wait_for_dns_default_ready_only_on_survivor
else
  log "Host SSH not attempted (no packet-conf.sh or IP empty)"
fi

log "Pre step complete (degraded mode). Exiting clean."
exit 0
