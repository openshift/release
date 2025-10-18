#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
log() { echo "[$(date -u +'%F %T%z')] $*"; }

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

# configurable capture window (kept for CI; not used for watchers anymore)
CAPTURE_LOOPS="${CAPTURE_LOOPS:-300}" # 300 * 2s = 600s
CAPTURE_INTERVAL="${CAPTURE_INTERVAL:-2}"

# --------------------------------------------------------------------
# Ensure 'oc' is available (CI-safe)
# --------------------------------------------------------------------
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
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
  else
    wget -qO- "$url" | tar -xz -C /tmp/ocbin oc
  fi
  chmod +x /tmp/ocbin/oc || true
  export PATH="/tmp/ocbin:$PATH"
  hash -r
fi
oc version --client | tee "${ART_BASE}/oc-version.txt" || true

# --------------------------------------------------------------------
# Focused image-registry capture
#   - pods (state, describe, logs), deploy/rs
#   - svc/endpoints/endpointslices for image-registry
#   - namespace events
#   - imagestreams (cluster-wide)
#   - operator config & CO for replicas/storage/conditions
# --------------------------------------------------------------------
collect_imageregistry() {
  local label="${1:-manual}" ts outdir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="${ART_BASE}/imageregistry-${label}-${ts}"
  mkdir -p "$outdir"
  echo "== Image Registry capture (${label}) -> ${outdir}"

  # Operator/config and CO (context: replicas/storage/conditions)
  oc get configs.imageregistry.operator.openshift.io/cluster -o yaml > "${outdir}/imageregistry-config.yaml" || true
  oc get co image-registry -o yaml > "${outdir}/co-image-registry.yaml" || true

  # Workloads and pods
  oc -n openshift-image-registry get deploy,rs -o wide > "${outdir}/workloads.txt" 2>&1 || true
  oc -n openshift-image-registry get pods -o wide > "${outdir}/pods-wide.txt" 2>&1 || true
  oc -n openshift-image-registry get pods -o yaml > "${outdir}/pods.yaml" 2>&1 || true
  for p in $(oc -n openshift-image-registry get pods -o name 2>/dev/null); do
    oc -n openshift-image-registry describe "$p" > "${outdir}/describe-$(basename "$p").txt" 2>&1 || true
    oc -n openshift-image-registry logs "$p" --all-containers --tail=-1 > "${outdir}/logs-$(basename "$p").txt" 2>&1 || true
  done

  # Service + Endpoints (+Slices)
  oc -n openshift-image-registry get svc image-registry -o yaml > "${outdir}/svc-image-registry.yaml" 2>&1 || true
  oc -n openshift-image-registry get endpoints image-registry -o yaml > "${outdir}/endpoints-image-registry.yaml" 2>&1 || true
  oc -n openshift-image-registry get endpointslices -l kubernetes.io/service-name=image-registry -o yaml \
    > "${outdir}/endpointslices-image-registry.yaml" 2>&1 || true

  # Namespace events (ordering helps correlate)
  oc -n openshift-image-registry get events --sort-by=.lastTimestamp > "${outdir}/events.txt" 2>&1 || true

  # Imagestreams (cluster-wide inventory)
  oc get is -A -o wide > "${outdir}/imagestreams-wide.txt" 2>&1 || true
  oc get is -A -o json > "${outdir}/imagestreams.json" 2>&1 || true

  oc get co > "${outdir}/cluster-operators.json" 2>&1 || true
}

# --------------------------------------------------------------------
# Guards used by CI job orchestration
# --------------------------------------------------------------------
if [[ -z "${DEGRADED_NODE:-}" ]]; then
  echo "DEGRADED_NODE is not set, skipping node degradation"
  exit 0
fi
if [[ "${DEGRADED_NODE}" != "true" ]]; then
  echo "DEGRADED_NODE is set to '${DEGRADED_NODE}', but not 'true', skipping node degradation"
  exit 0
fi
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Packet/hypervisor connection details (SSHOPTS, IP, etc.)
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# --------------------------------------------------------------------
# Pre-degradation capture
# --------------------------------------------------------------------
sleep 1200
collect_imageregistry "pre-degradation"


# --------------------------------------------------------------------
# Degrade the node (keep logic unchanged)
# --------------------------------------------------------------------
echo "Connecting to packet system to degrade ostest_master_1..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<"EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -xeo pipefail
set -o nounset
set -o errexit
set -o pipefail

echo "Connected to packet system, listing VMs..."
virsh -c qemu:///system list --all

echo "Looking for ostest_master_1 node..."
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
  echo "Shutting down ostest_master_1..."
  virsh -c qemu:///system shutdown ostest_master_1 || true

  echo "Getting DHCP leases to find ostest_master_0 IP..."
  virsh -c qemu:///system net-dhcp-leases ostestbm
  MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm | grep master-0 | awk '{print $5}' | cut -d'/' -f1)
  if [[ -z "${MASTER0_IP}" ]]; then
    echo "ERROR: Could not find ostest_master_0 IP address in DHCP leases"; exit 1
  fi

  echo "Connecting to ostest_master_0 to run pcs commands..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 core@"${MASTER0_IP}" << 'MASTER0_EOF'
    echo "Running: sudo pcs resource status";                 sudo pcs resource status
    echo "Running: sudo pcs property set stonith-enabled=false"; sudo pcs property set stonith-enabled=false
    echo "Running: sudo pcs resource cleanup etcd";           sudo pcs resource cleanup etcd
    echo "Running: sudo pcs resource status (final)";         sudo pcs resource status
MASTER0_EOF

else
  echo "WARNING: ostest_master_1 not found or not accessible"
  virsh -c qemu:///system list --all
  exit 1
fi

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all
EOF

# --------------------------------------------------------------------
# Post-degradation captures
#   - immediate
#   - after 10 minutes
# --------------------------------------------------------------------
collect_imageregistry "post-degradation-immediate"

sleep 600
collect_imageregistry "post-degradation-10m"

log "Node degradation and focused image-registry capture completed."
log "Artifacts under: ${ART_BASE}"
