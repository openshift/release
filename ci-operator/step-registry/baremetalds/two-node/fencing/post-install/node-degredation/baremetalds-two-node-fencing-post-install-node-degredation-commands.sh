#!/bin/bash
set -euo pipefail

# Variables
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
prepare_test_image_config() {
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/ds-vars.conf"

  # IPv6 clusters are disconnected. IDMS is available starting with OCP 4.13.
  if [[ "${DS_IP_STACK}" != "v6" ]] || ! printf '%s\n%s' "4.13" "${DS_OPENSHIFT_VERSION}" | sort -C -V; then
    return 0
  fi

  local test_image_repo="${DS_REGISTRY}/localimages/local-test-image"
  log "Configuring the test image mirror before degrading the cluster..."
  ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${test_image_repo}" << 'IDMS_EOF'
set -euo pipefail
local_repo="$1"
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: test-image-idms
spec:
  imageDigestMirrors:
  - source: quay.io/openshifttest/hello-sdn
    mirrors:
    - ${local_repo}
EOF

# Updated=True alone can still describe the configuration preceding the IDMS.
# First verify that the desired rendered config contains the mirror, then check
# that all masters have applied it. Do not wait for Updating=True: a fast/no-op
# rollout can miss that transition, and the empty worker pool never needs one.
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
    if pool=$(oc get mcp master -o json); then
        rendered_config=$(jq -r '.spec.configuration.name' <<< "${pool}")
        if registries_conf=$(oc get machineconfig "${rendered_config}" -o json | jq -r '
            .spec.config.storage.files[]
            | select(.path == "/etc/containers/registries.conf")
            | .contents.source | split(",")[1] | @base64d') &&
            [[ "${registries_conf}" == *'"quay.io/openshifttest/hello-sdn"'* && "${registries_conf}" == *"\"${local_repo}\""* ]] &&
            jq -e '
                .status.observedGeneration >= .metadata.generation and
                .status.configuration.name == .spec.configuration.name and
                .status.machineCount > 0 and
                .status.updatedMachineCount == .status.machineCount and
                .status.readyMachineCount == .status.machineCount and
                any(.status.conditions[]; .type == "Updated" and .status == "True")
            ' <<< "${pool}" > /dev/null; then
            echo "All masters have applied the test image mirror configuration."
            exit 0
        fi
    fi
    sleep 10
done

echo "Timed out waiting for masters to apply the test image mirror configuration."
oc get mcp master
exit 1
IDMS_EOF

  # Record success only after all masters have applied the mirror configuration.
  # The e2e step will mirror image contents and reuse this IDMS after shutdown.
  printf '%s\n' "${test_image_repo}" > "${SHARED_DIR}/test-image-idms-prepared"
}

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


# Host SSH setup (optional)
SKIP_HOST_SSH="${SKIP_HOST_SSH:-0}"

if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  log "packet-conf.sh not found in SHARED_DIR; skipping host SSH actions"
  SKIP_HOST_SSH=1
else
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/packet-conf.sh"
fi

# Complete cluster-wide configuration while both masters can apply it. A failure
# here must stop the step before we intentionally take master-1 offline.
if [[ ${SKIP_HOST_SSH} -eq 0 && -n "${IP:-}" ]]; then
  prepare_test_image_config
fi

# Keep the original 20-minute stabilization/degradation budget after IDMS setup.
GLOBAL_DEADLINE=$(( $(date +%s) + 1200 ))
wait_for_image_registry_stable

# Degrade master-1 via hypervisor
if [[ ${SKIP_HOST_SSH} -eq 0 && -n "${IP:-}" ]]; then
  log "Degrading ostest_master_1 via hypervisor @ ${IP}"

  set +e
  timeout -s 9 5m ssh "${SSHOPTS[@]}" root@"${IP}" bash -s << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -euo pipefail

if ! command -v virsh >/dev/null 2>&1; then
  echo "[host] virsh not found, aborting host actions"
  exit 0
fi

NET="ostestbm"
echo "[host] DHCP leases (${NET}):"
virsh -c qemu:///system net-dhcp-leases "${NET}" || true

MASTER0_IP="$(virsh -c qemu:///system net-dhcp-leases "${NET}" 2>/dev/null | awk '/master-0/ {print $5}' | cut -d/ -f1 | head -n1)"

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

# Manual recovery on the surviving node (master-0) WITHOUT disabling stonith.
# Force-start etcd on the survivor while keeping fencing enabled.
if [[ -n "${MASTER0_IP:-}" ]]; then
  echo "[host] Attempting manual recovery on master-0 (${MASTER0_IP}) via pcs debug-stop/debug-start..."
  timeout 180s ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
    core@"${MASTER0_IP}" << 'PCS_EOF'
set -euo pipefail

echo "[master-0] pcs status (pre):"
sudo pcs status || true
sudo pcs resource status || true

# Break any stuck recovery attempts (best-effort)
echo "[master-0] debug-stop etcd (best-effort)..."
sudo pcs resource debug-stop etcd || true

# Wait for etcd ports to be released before restarting.
# debug-stop uses 'podman stop -t=80' which can take up to ~90s to fully
# release ports 2379/2380. debug-start's internal port wait is only 60s,
# so without this explicit wait the start can time out.
echo "[master-0] waiting for etcd ports 2379/2380 to be released..."
for _i in $(seq 1 120); do
  if ! ss -Htan '( sport = 2379 or sport = 2380 )' | grep -q .; then
    echo "[master-0] etcd ports released after ${_i}s"
    break
  fi
  sleep 1
done

# Force start etcd on survivor with the notify meta env var required by the RA
echo "[master-0] debug-start etcd with notify meta env var..."
sudo OCF_RESKEY_CRM_meta_notify_start_resource='etcd' pcs resource debug-start etcd

# Cleanup so pacemaker re-evaluates state cleanly (best-effort)
sudo pcs resource cleanup etcd || true

echo "[master-0] pcs status (post):"
sudo pcs status || true
sudo pcs resource status || true
PCS_EOF
fi
EOF
  ssh_rc=${PIPESTATUS[0]}
  set -e

  if [[ ${ssh_rc} -ne 0 ]]; then
    log "ERROR: Failed to degrade ostest_master_1 via hypervisor (rc=${ssh_rc})"
    exit ${ssh_rc}
  fi
else
  log "Host SSH not attempted (no packet-conf.sh or IP empty)"
fi

log "Pre step complete (degraded mode). Exiting clean."
exit 0
