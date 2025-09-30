#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
log() { echo "[$(date +'%F %T%z')] $*"; }

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

if ! command -v oc >/dev/null 2>&1; then
	log "oc not found, installing client..."
	CLI_TAG_LOCAL="${CLI_TAG:-4.20}"
	UNAME_M="$(uname -m)"
	case "$UNAME_M" in
	x86_64) OC_TARBALL="openshift-client-linux.tar.gz" ;;
	aarch64 | arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
	*)
		log "Unsupported arch: $UNAME_M"
		exit 1
		;;
	esac
	url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
	mkdir -p /tmp/ocbin
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
	else wget -qO- "$url" | tar -xz -C /tmp/ocbin oc; fi
	chmod +x /tmp/ocbin/oc || true
	export PATH="/tmp/ocbin:$PATH"
	hash -r
fi
oc version --client | tee "${ART_BASE}/oc-version.txt" || true

snapshot_cluster() {
	local label="$1"
	local ts
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	local outdir="${ART_BASE}/${label}-${ts}"
	mkdir -p "${outdir}"

	echo "== Snapshot (${label}) -> ${outdir}"

	# 1) Image Registry config (yaml)
	oc get configs.imageregistry.operator.openshift.io/cluster -o yaml \
		>"${outdir}/imageregistry-config.yaml" || true

	# 2) Image Registry CO conditions (yaml tail from conditions:)
	oc get co image-registry -o yaml | sed -n '/^  conditions:/,$p' \
		>"${outdir}/image-registry-co-conditions.yaml" || true

	# 3) openshift-etcd Jobs (table)
	oc get jobs -n openshift-etcd \
		>"${outdir}/openshift-etcd-jobs.txt" || true

	# 4) All ClusterOperators wide
	oc get co -o wide \
		>"${outdir}/clusteroperators-wide.txt" || true

	# 5) etcd ClusterOperator (both wide & yaml for depth)
	oc get co etcd -o wide \
		>"${outdir}/co-etcd-wide.txt" || true
	oc get co etcd -o yaml \
		>"${outdir}/co-etcd.yaml" || true

	# Bonus: store oc get events around etcd/operator (optional; comment out if noisy)
	oc -n openshift-etcd get events --sort-by=.lastTimestamp \
		>"${outdir}/events-openshift-etcd.txt" || true
	oc -n openshift-etcd-operator get events --sort-by=.lastTimestamp \
		>"${outdir}/events-openshift-etcd-operator.txt" || true
}

# Check if DEGRADED_NODE is unset or empty
if [[ -z "${DEGRADED_NODE:-}" ]]; then
	echo "DEGRADED_NODE is not set, skipping node degradation"
	exit 0
fi

# Check if DEGRADED_NODE is set to "true"
if [[ "${DEGRADED_NODE}" != "true" ]]; then
	echo "DEGRADED_NODE is set to '${DEGRADED_NODE}', but not 'true', skipping node degradation"
	exit 0
fi

echo "DEGRADED_NODE is set to true, proceeding with node degradation..."

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
	echo "No server IP found; skipping log gathering."
	exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
snapshot_cluster "before-degradation"

# SSH to the packet system and degrade the second node
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
    echo "Found ostest_master_1, proceeding with degradation..."

    #echo "Undefining ostest_master_1..."
    #virsh -c qemu:///system undefine ostest_master_1 --nvram|| true

    #echo "Destroying ostest_master_1..."
    #virsh -c qemu:///system destroy ostest_master_1 || true

    #echo "ostest_master_1 has been degraded (undefined and destroyed)"

    echo "Shutting down ostest_master_1..."
    virsh -c qemu:///system shutdown ostest_master_1 || true

    echo "Getting DHCP leases to find ostest_master_1 IP..."
    virsh -c qemu:///system net-dhcp-leases ostestbm

    # Extract ostest_master_0 IP address from DHCP leases
    MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm | grep master-0 | awk '{print $5}' | cut -d'/' -f1)

    if [[ -z "${MASTER0_IP}" ]]; then
        echo "ERROR: Could not find ostest_master_0 IP address in DHCP leases"
        exit 1
    fi

    echo "Found ostest_master_0 IP: ${MASTER0_IP}"
    echo "Connecting to ostest_master_0 to run pcs commands..."

    # SSH to ostest_master_0 and run pcs commands
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 core@"${MASTER0_IP}" << 'MASTER0_EOF'

    echo "Connected to ostest_master_0, running pcs commands..."

    echo "Running: sudo pcs resource status"
    sudo pcs resource status

    echo "Running: sudo pcs property set stonith-enabled=false"
    sudo pcs property set stonith-enabled=false

    echo "Running: sudo pcs resource cleanup etcd"
    sudo pcs resource cleanup etcd

    echo "Running: sudo pcs resource status (final check)"
    sudo pcs resource status

    echo "pcs commands completed successfully on ostest_master_0"

MASTER0_EOF

    echo "Successfully ran pcs commands on ostest_master_0"

else
    echo "WARNING: ostest_master_1 not found or not accessible"
    virsh -c qemu:///system list --all
    exit 1
fi

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all

EOF
snapshot_cluster "after-degradation"

echo "Node degradation and pcs commands completed successfully"
