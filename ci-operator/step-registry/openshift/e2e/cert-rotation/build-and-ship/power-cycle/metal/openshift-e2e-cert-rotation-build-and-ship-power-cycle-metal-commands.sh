#!/bin/bash
# Build-and-ship test, step 2 of 3 (dev-scripts metal): shut down every cluster VM on the host, then
# start them again.
set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
want=$(cat "${SHARED_DIR}/build-and-ship-node-count")

timeout -s 9 40m ssh "${SSHOPTS[@]}" "root@${IP}" bash -s "${want}" "${STOP_TIMEOUT}" <<'REMOTE'
set -eo pipefail
want=$1
stop_timeout=$2
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
cd /root/dev-scripts
# common.sh (for CLUSTER_NAME) isn't nounset-safe and turns on xtrace.
# shellcheck source=/dev/null
source common.sh
set +x
set -u
mapfile -t vms < <(virsh list --state-running --name | grep "^${CLUSTER_NAME}_" || true)
if ((${#vms[@]} != want)); then
  log "ERROR: found ${#vms[@]} running cluster VMs (${vms[*]:-none}) but the cluster has ${want} nodes"
  exit 1
fi
all_in() { # state
  local v
  for v in "${vms[@]}"; do [[ $(virsh domstate "$v") == "$1" ]] || return 1; done
}
log "shutting down: ${vms[*]}"
for v in "${vms[@]}"; do virsh shutdown "$v" >/dev/null; done
deadline=$(($(date +%s) + stop_timeout))
until all_in "shut off"; do
  if (($(date +%s) > deadline)); then
    log "VMs did not shut down within ${stop_timeout}s; destroying"
    for v in "${vms[@]}"; do virsh destroy "$v" >/dev/null 2>&1 || true; done
    sleep 10
    all_in "shut off" || { log "ERROR: VMs still not off"; exit 1; }
    break
  fi
  sleep 10
done
log "all VMs shut off; starting"
for v in "${vms[@]}"; do virsh start "$v" >/dev/null; done
deadline=$(($(date +%s) + 600))
until all_in running; do
  (($(date +%s) < deadline)) || { log "ERROR: VMs not running within 10m"; exit 1; }
  sleep 5
done
log "all VMs running again"
REMOTE
date -u +%s >"${SHARED_DIR}/build-and-ship-running-at"
