#!/bin/bash
set -euo pipefail
shopt -s inherit_errexit

# --- Trace-to-file: always capture, dump on failure only ---
_xtrace_log="/tmp/xtrace-$(basename "$0" .sh).log"
exec {_xtrace_fd}>"${_xtrace_log}"
BASH_XTRACEFD=${_xtrace_fd}
set -x

# shellcheck disable=SC2154
_opp_cleanup() {
  _exit_code=$?
  set +x 2>/dev/null
  # Scrub credentials before copying
  sed -i -E \
    -e 's/(password|token|secret|key|credential)=[^ ]*/\1=REDACTED/gi' \
    -e 's/Bearer [A-Za-z0-9._~+\/=-]+/Bearer [REDACTED]/g' \
    -e 's/password=[^ &]+/password=[REDACTED]/g' \
    -e 's/token=[^ &]+/token=[REDACTED]/g' \
    -e 's|://[^:@/]*:[^:@/]*@|://[REDACTED]:[REDACTED]@|g' \
    "${_xtrace_log}" 2>/dev/null || true
  if [[ ${_exit_code} -ne 0 && -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${_xtrace_log}" "${ARTIFACT_DIR}/" 2>/dev/null || true
    echo ">>> TRACE: xtrace log saved to artifacts (exit code ${_exit_code})"
  fi
}

# --- JUnit XML wrapper: emit result for skip-ratio-gate ---
_junit_start=$(date +%s)
_junit_emitted=0
_jrc=0  # initialized here, assigned inside trap string
_junit_emit() {
  (( _junit_emitted )) && return 0
  _junit_emitted=1
  local _jr=${1:-0}
  local _je
  _je=$(date +%s) || _je=${_junit_start}
  local _jd=$((_je - _junit_start))
  local _jn="backup"
  local _jf="${ARTIFACT_DIR:-/tmp}/junit_lp-interop--OPP--${_jn}.xml"
  local _fc=0 _fx=""
  if (( _jr != 0 )); then
    _fc=1
    _fx="<failure message=\"${_jn} exited with code ${_jr}\" type=\"StepFailure\">Step exited with code ${_jr}</failure>"
  fi
  cat > "${_jf}" <<JUNITEOF || true
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="lp-interop--OPP--${_jn}" tests="1" failures="${_fc}" errors="0" skipped="0" time="${_jd}">
  <testcase name="${_jn}" classname="lp-interop.OPP.${_jn}" time="${_jd}">
    ${_fx}
  </testcase>
</testsuite>
JUNITEOF
  if [[ -n "${SHARED_DIR:-}" ]]; then
    mkdir -p "${SHARED_DIR}/junit" 2>/dev/null || true
    cp "${_jf}" "${SHARED_DIR}/junit/" 2>/dev/null || true
  fi
}

trap '_jrc=$?; set +e; _junit_emit ${_jrc}; (exit ${_jrc}); _opp_cleanup; exit ${_jrc}' EXIT

echo ">>> PHASE: initialization"

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
    typeset description="${1:-}"; (($#)) && shift
    typeset outputFile="${1:-}"; (($#)) && shift
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
trap '_jrc=$?; set +e; _junit_emit ${_jrc}; (exit ${_jrc}); _opp_cleanup; kill ${timeoutPid} || true; exit ${_jrc}' EXIT
trap 'kill ${timeoutPid} || true; exit 124' TERM

echo ">>> PHASE: Pre-Upgrade Cluster Backup"
: "Start time: $(date '+%F %T')"
: "Backup timeout: ${BACKUP_TIMEOUT}s"

# --- Etcd snapshot ---
echo ">>> PHASE: Etcd Snapshot"
typeset controlPlaneNode=""
controlPlaneNode=$(oc get nodes -l node-role.kubernetes.io/master="" -o jsonpath='{.items[0].metadata.name}') || true
if [[ -n "${controlPlaneNode}" ]]; then
    : "Found control-plane node"
    typeset etcdBackupRemote="/home/core/assets/backup"
    if oc debug "node/${controlPlaneNode}" -- chroot /host /usr/local/bin/cluster-backup.sh "${etcdBackupRemote}" 2>&1; then
        # Copy snapshot and static-pod resources from the node
        typeset snapshotFile=""
        snapshotFile=$(oc debug "node/${controlPlaneNode}" -- chroot /host \
            bash -c "ls -1 ${etcdBackupRemote}/snapshot_*.db | head -1") || true
        typeset resourcesFile=""
        resourcesFile=$(oc debug "node/${controlPlaneNode}" -- chroot /host \
            bash -c "ls -1 ${etcdBackupRemote}/static_kuberesources_*.tar.gz | head -1") || true

        typeset isCopyOk=true
        if [[ -z "${snapshotFile}" || -z "${resourcesFile}" ]]; then
            : "WARNING: Backup files not found (snapshot=${snapshotFile:-empty}, resources=${resourcesFile:-empty})"
            isCopyOk=false
        fi
        if [[ -n "${snapshotFile}" ]]; then
            if ! oc debug "node/${controlPlaneNode}" -- cat "/host${snapshotFile}" > "${backupDir}/etcd-snapshot.db" 2>&1; then
                : "WARNING: Failed to copy etcd snapshot (continuing)"
                isCopyOk=false
            fi
        fi
        if [[ -n "${resourcesFile}" ]]; then
            if ! oc debug "node/${controlPlaneNode}" -- cat "/host${resourcesFile}" > "${backupDir}/static-kuberesources.tar.gz" 2>&1; then
                : "WARNING: Failed to copy static kube resources (continuing)"
                isCopyOk=false
            fi
        fi

        if [[ "${isCopyOk}" == "true" ]]; then
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
echo ">>> PHASE: Control Plane State"
Capture "ClusterVersion" "${backupDir}/clusterversion.yaml" \
    oc get clusterversion version -o yaml

Capture "ClusterOperators" "${backupDir}/clusteroperators.yaml" \
    oc get clusteroperators -o yaml

Capture "Nodes" "${backupDir}/nodes.yaml" \
    oc get nodes -o yaml

Capture "MachineConfigPools" "${backupDir}/machineconfigpools.yaml" \
    oc get machineconfigpools -o yaml

# --- OPP operator state ---
echo ">>> PHASE: OPP Operator State"
Capture "CSVs" "${backupDir}/csvs.yaml" \
    oc get csv -A -o yaml

Capture "Subscriptions" "${backupDir}/subscriptions.yaml" \
    oc get subscriptions.operators.coreos.com -A -o yaml

Capture "InstallPlans" "${backupDir}/installplans.yaml" \
    oc get installplans -A -o yaml

# --- Backup manifest ---
echo ">>> PHASE: Generating Backup Manifest"
typeset clusterVersion=""
clusterVersion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}') || true

typeset -i nodeCount=0
nodeCount=$(oc get nodes -o json | jq '.items | length') || true

typeset -a opListArr=()
IFS=',' read -ra opListArr <<< "${OPP_OPERATORS}"
typeset opJson="["
typeset csvPhase=""
for op in "${opListArr[@]}"; do
    csvPhase=""
    csvPhase=$(oc get csv -A -o json | jq -r --arg op "${op}" '[.items[] | select(.metadata.name | contains($op))][0].status.phase // "unknown"') || true
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
echo ">>> PHASE: Backup Summary"
: "End time: $(date '+%F %T')"
: "Cluster version: ${clusterVersion:-unknown}"
: "Node count: ${nodeCount}"
: "Artifacts captured: ${captured}"
: "Capture failures: ${failures}"
: "Backup directory contents:"
ls -lh "${backupDir}/"

: "Pre-upgrade backup complete"
true
