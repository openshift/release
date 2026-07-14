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
trap 'kill ${TIMEOUT_PID} 2>/dev/null || true' EXIT
trap 'kill ${TIMEOUT_PID} 2>/dev/null || true; exit 124' TERM

echo "=== Pre-Upgrade Cluster Backup ==="
echo "Start time: $(date '+%F %T')"
echo "Backup timeout: ${BACKUP_TIMEOUT}s"
echo ""

# --- Etcd snapshot ---
echo "--- Etcd Snapshot ---"
CONTROL_PLANE_NODE=""
CONTROL_PLANE_NODE=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [[ -n "${CONTROL_PLANE_NODE}" ]]; then
    echo "Found control-plane node"
    ETCD_BACKUP_REMOTE="/home/core/assets/backup"
    if oc debug "node/${CONTROL_PLANE_NODE}" -- chroot /host /usr/local/bin/cluster-backup.sh "${ETCD_BACKUP_REMOTE}" 2>&1; then
        # Copy snapshot and static-pod resources from the node
        SNAPSHOT_FILE=$(oc debug "node/${CONTROL_PLANE_NODE}" -- chroot /host \
            bash -c "ls -1 ${ETCD_BACKUP_REMOTE}/snapshot_*.db 2>/dev/null | head -1" 2>/dev/null) || true
        RESOURCES_FILE=$(oc debug "node/${CONTROL_PLANE_NODE}" -- chroot /host \
            bash -c "ls -1 ${ETCD_BACKUP_REMOTE}/static_kuberesources_*.tar.gz 2>/dev/null | head -1" 2>/dev/null) || true

        COPY_OK=true
        if [[ -n "${SNAPSHOT_FILE}" ]]; then
            if ! oc debug "node/${CONTROL_PLANE_NODE}" -- cat "/host${SNAPSHOT_FILE}" > "${BACKUP_DIR}/etcd-snapshot.db" 2>&1; then
                echo "  WARNING: Failed to copy etcd snapshot (continuing)"
                COPY_OK=false
            fi
        fi
        if [[ -n "${RESOURCES_FILE}" ]]; then
            if ! oc debug "node/${CONTROL_PLANE_NODE}" -- cat "/host${RESOURCES_FILE}" > "${BACKUP_DIR}/static-kuberesources.tar.gz" 2>&1; then
                echo "  WARNING: Failed to copy static kube resources (continuing)"
                COPY_OK=false
            fi
        fi

        if [[ "${COPY_OK}" == "true" ]]; then
            echo "  OK: etcd snapshot and static kube resources saved"
            (( CAPTURED += 1 ))
        else
            (( FAILURES += 1 ))
        fi
        # Clean up backup files on the node
        oc debug "node/${CONTROL_PLANE_NODE}" -- chroot /host \
            rm -rf "${ETCD_BACKUP_REMOTE}" 2>/dev/null || true
    else
        echo "  WARNING: Failed to create etcd backup via cluster-backup.sh (continuing)"
        echo "  This is expected in some CI environments due to permissions"
        (( FAILURES += 1 ))
    fi
else
    echo "  WARNING: No control-plane node found (continuing)"
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
