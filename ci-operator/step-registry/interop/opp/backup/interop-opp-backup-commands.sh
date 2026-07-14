#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# NOTE: BACKUP_TIMEOUT and OPP_OPERATORS are set via step config YAML (naming deviates from OPP__ convention)
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-300}"
OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

typeset backupDir="${ARTIFACT_DIR}/cluster-backup"
mkdir -p "${backupDir}"

typeset -i failures=0
typeset -i captured=0

Capture() {
    typeset description="${1}" outputFile="${2}"
    shift 2
    : "Capturing ${description}..."
    if "$@" > "${outputFile}" 2>&1; then
        : "OK: ${description} -> $(basename "${outputFile}")"
        (( captured += 1 ))
    else
        : "WARNING: Failed to capture ${description} (continuing)"
        (( failures += 1 ))
    fi
}

TimeoutMonitor() {
    typeset -i startTime=0
    startTime=$(date +%s)
    typeset -i deadline=$(( startTime + BACKUP_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        sleep 10
    done
    : "ERROR: Backup timed out after ${BACKUP_TIMEOUT} seconds"
    kill -TERM $$ || true
}

# Start timeout monitor in background
TimeoutMonitor &
typeset timeoutPid=$!
trap 'kill ${timeoutPid} || true' EXIT
trap 'kill ${timeoutPid} || true; exit 124' TERM

: "=== Pre-Upgrade Cluster Backup ==="
: "Start time: $(date '+%F %T')"
: "Backup timeout: ${BACKUP_TIMEOUT}s"

# --- Etcd snapshot ---
: "--- Etcd Snapshot ---"
typeset controlPlaneNode=""
controlPlaneNode=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}') || true
if [[ -n "${controlPlaneNode}" ]]; then
    : "Found control-plane node"
    typeset etcdBackupRemote="/home/core/assets/backup"
    if oc debug "node/${controlPlaneNode}" -- chroot /host /usr/local/bin/cluster-backup.sh "${etcdBackupRemote}" 2>&1; then
        # Copy snapshot and static-pod resources from the node
        typeset snapshotFile=""
        snapshotFile=$(oc debug "node/${controlPlaneNode}" -- chroot /host \
            bash -c "ls -1 ${etcdBackupRemote}/snapshot_*.db 2>/dev/null | head -1") || true
        typeset resourcesFile=""
        resourcesFile=$(oc debug "node/${controlPlaneNode}" -- chroot /host \
            bash -c "ls -1 ${etcdBackupRemote}/static_kuberesources_*.tar.gz 2>/dev/null | head -1") || true

        typeset copyOk=true
        if [[ -n "${snapshotFile}" ]]; then
            if ! oc debug "node/${controlPlaneNode}" -- cat "/host${snapshotFile}" > "${backupDir}/etcd-snapshot.db" 2>&1; then
                : "WARNING: Failed to copy etcd snapshot (continuing)"
                copyOk=false
            fi
        fi
        if [[ -n "${resourcesFile}" ]]; then
            if ! oc debug "node/${controlPlaneNode}" -- cat "/host${resourcesFile}" > "${backupDir}/static-kuberesources.tar.gz" 2>&1; then
                : "WARNING: Failed to copy static kube resources (continuing)"
                copyOk=false
            fi
        fi

        if [[ "${copyOk}" == "true" ]]; then
            : "OK: etcd snapshot and static kube resources saved"
            (( captured += 1 ))
        else
            (( failures += 1 ))
        fi
        # Clean up backup files on the node
        oc debug "node/${controlPlaneNode}" -- chroot /host \
            rm -rf "${etcdBackupRemote}" || true
    else
        : "WARNING: Failed to create etcd backup via cluster-backup.sh (continuing)"
        : "This is expected in some CI environments due to permissions"
        (( failures += 1 ))
    fi
else
    : "WARNING: No control-plane node found (continuing)"
    (( failures += 1 ))
fi

# --- Control plane resource state ---
: "--- Control Plane State ---"
Capture "ClusterVersion" "${backupDir}/clusterversion.yaml" \
    oc get clusterversion version -o yaml

Capture "ClusterOperators" "${backupDir}/clusteroperators.yaml" \
    oc get clusteroperators -o yaml

Capture "Nodes" "${backupDir}/nodes.yaml" \
    oc get nodes -o yaml

Capture "MachineConfigPools" "${backupDir}/machineconfigpools.yaml" \
    oc get machineconfigpools -o yaml

# --- OPP operator state ---
: "--- OPP Operator State ---"
Capture "CSVs" "${backupDir}/csvs.yaml" \
    oc get csv -A -o yaml

Capture "Subscriptions" "${backupDir}/subscriptions.yaml" \
    oc get subscriptions.operators.coreos.com -A -o yaml

Capture "InstallPlans" "${backupDir}/installplans.yaml" \
    oc get installplans -A -o yaml

# --- Backup manifest ---
: "--- Generating Backup Manifest ---"
typeset clusterVersion=""
clusterVersion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || true

typeset -i nodeCount=0
nodeCount=$(oc get nodes -o json | jq '.items | length') || true

typeset -a opList=()
IFS=',' read -ra opList <<< "${OPP_OPERATORS}"
typeset opJson="["
typeset csvPhase=""
for op in "${opList[@]}"; do
    csvPhase=""
    csvPhase=$(oc get csv -A --no-headers | grep "${op}" | head -1 | awk '{print $NF}') || true
    opJson="${opJson}{\"name\":\"${op}\",\"phase\":\"${csvPhase:-unknown}\"},"
done
opJson="${opJson%,}]"

cat > "${backupDir}/backup-manifest.json" <<EOF
{
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "cluster_version": "${clusterVersion:-unknown}",
    "node_count": ${nodeCount},
    "operators": ${opJson},
    "artifacts_captured": ${captured},
    "capture_failures": ${failures}
}
EOF
: "OK: backup-manifest.json"

# --- Summary ---
: "=== Backup Summary ==="
: "End time: $(date '+%F %T')"
: "Cluster version: ${clusterVersion:-unknown}"
: "Node count: ${nodeCount}"
: "Artifacts captured: ${captured}"
: "Capture failures: ${failures}"
: "Backup directory contents:"
ls -lh "${backupDir}/"

: "Pre-upgrade backup complete"
true
