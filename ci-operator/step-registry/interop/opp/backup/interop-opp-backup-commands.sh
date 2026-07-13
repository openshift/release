#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-300}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

BACKUP_DIR="${ARTIFACT_DIR}/cluster-backup"
mkdir -p "${BACKUP_DIR}"

FAILURES=0
CAPTURED=0

capture() {
    local description="${1}" output_file="${2}"
    shift 2
    echo "Capturing ${description}..."
    if "$@" > "${output_file}" 2>&1; then
        echo "  OK: ${description} -> $(basename "${output_file}")"
        (( CAPTURED += 1 ))
    else
        echo "  WARNING: Failed to capture ${description} (continuing)"
        (( FAILURES += 1 ))
    fi
}

timeout_monitor() {
    local start_time
    start_time=$(date +%s)
    local deadline=$(( start_time + BACKUP_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        sleep 10
    done
    echo >&2 "ERROR: Backup timed out after ${BACKUP_TIMEOUT} seconds"
    kill -TERM $$ 2>/dev/null || true
}

# Start timeout monitor in background
timeout_monitor &
TIMEOUT_PID=$!
trap 'kill ${TIMEOUT_PID} 2>/dev/null || true' EXIT TERM

echo "=== Pre-Upgrade Cluster Backup ==="
echo "Start time: $(date '+%F %T')"
echo "Backup timeout: ${BACKUP_TIMEOUT}s"
echo ""

# --- Etcd snapshot ---
echo "--- Etcd Snapshot ---"
ETCD_POD=""
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [[ -n "${ETCD_POD}" ]]; then
    echo "Found etcd pod: ${ETCD_POD}"
    if oc exec -n openshift-etcd "${ETCD_POD}" -c etcdctl -- \
        etcdctl snapshot save /var/lib/etcd/snapshot.db 2>&1; then
        if oc cp "openshift-etcd/${ETCD_POD}:/var/lib/etcd/snapshot.db" \
            "${BACKUP_DIR}/etcd-snapshot.db" -c etcdctl 2>&1; then
            echo "  OK: etcd snapshot saved"
            (( CAPTURED += 1 ))
        else
            echo "  WARNING: Failed to copy etcd snapshot (continuing)"
            (( FAILURES += 1 ))
        fi
        # Clean up snapshot inside pod
        oc exec -n openshift-etcd "${ETCD_POD}" -c etcdctl -- \
            rm -f /var/lib/etcd/snapshot.db 2>/dev/null || true
    else
        echo "  WARNING: Failed to create etcd snapshot (continuing)"
        echo "  This is expected in some CI environments due to permissions"
        (( FAILURES += 1 ))
    fi
else
    echo "  WARNING: No etcd pod found (continuing)"
    (( FAILURES += 1 ))
fi
echo ""

# --- Control plane resource state ---
echo "--- Control Plane State ---"
capture "ClusterVersion" "${BACKUP_DIR}/clusterversion.yaml" \
    oc get clusterversion version -o yaml

capture "ClusterOperators" "${BACKUP_DIR}/clusteroperators.yaml" \
    oc get clusteroperators -o yaml

capture "Nodes" "${BACKUP_DIR}/nodes.yaml" \
    oc get nodes -o yaml

capture "MachineConfigPools" "${BACKUP_DIR}/machineconfigpools.yaml" \
    oc get machineconfigpools -o yaml
echo ""

# --- OPP operator state ---
echo "--- OPP Operator State ---"
capture "CSVs" "${BACKUP_DIR}/csvs.yaml" \
    oc get csv -A -o yaml

capture "Subscriptions" "${BACKUP_DIR}/subscriptions.yaml" \
    oc get subscriptions.operators.coreos.com -A -o yaml

capture "InstallPlans" "${BACKUP_DIR}/installplans.yaml" \
    oc get installplans -A -o yaml
echo ""

# --- Backup manifest ---
echo "--- Generating Backup Manifest ---"
CLUSTER_VERSION=""
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || true

NODE_COUNT=""
NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l) || true

IFS=',' read -ra OP_LIST <<< "${OPP_OPERATORS}"
OP_JSON="["
for op in "${OP_LIST[@]}"; do
    csv_phase=""
    csv_phase=$(oc get csv -A --no-headers 2>/dev/null | grep "${op}" | head -1 | awk '{print $NF}') || true
    OP_JSON="${OP_JSON}{\"name\":\"${op}\",\"phase\":\"${csv_phase:-unknown}\"},"
done
OP_JSON="${OP_JSON%,}]"

cat > "${BACKUP_DIR}/backup-manifest.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${CLUSTER_VERSION:-unknown}",
    "node_count": ${NODE_COUNT:-0},
    "operators": ${OP_JSON},
    "artifacts_captured": ${CAPTURED},
    "capture_failures": ${FAILURES}
}
EOF
echo "  OK: backup-manifest.json"
echo ""

# --- Summary ---
echo "=== Backup Summary ==="
echo "End time: $(date '+%F %T')"
echo "Cluster version: ${CLUSTER_VERSION:-unknown}"
echo "Node count: ${NODE_COUNT:-unknown}"
echo "Artifacts captured: ${CAPTURED}"
echo "Capture failures: ${FAILURES}"
echo "Backup directory contents:"
ls -lh "${BACKUP_DIR}/"
echo ""
echo "Pre-upgrade backup complete"
