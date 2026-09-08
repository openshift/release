#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-${OPERATOR_NAME}}"
OPERATOR_DEPLOYMENT_NAME="${OPERATOR_DEPLOYMENT_NAME:-${OPERATOR_NAME}}"

log "Collecting e2e coverage for ${OPERATOR_NAME}"

# Find the operator pod
POD=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "app=${OPERATOR_DEPLOYMENT_NAME}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)
if [[ -z "${POD}" ]]; then
    log "WARNING: No operator pod found, trying alternate label"
    POD=$(oc get pod -n "${OPERATOR_NAMESPACE}" --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep "${OPERATOR_DEPLOYMENT_NAME}" | head -1)
fi

if [[ -z "${POD}" ]]; then
    log "ERROR: Could not find operator pod in ${OPERATOR_NAMESPACE}"
    exit 0
fi

log "Found pod: ${POD}"

# SIGTERM PID 1 to flush coverage data (emptyDir survives container restart)
log "Sending SIGTERM to flush coverage data"
oc exec -n "${OPERATOR_NAMESPACE}" "${POD}" -- kill -TERM 1 2>/dev/null || true
log "Waiting for coverage data to flush"
sleep 15

# Copy coverage data from the emptyDir volume
mkdir -p "${ARTIFACT_DIR}/coverage"
log "Copying coverage data from pod"
# Try oc cp first (needs tar in container), fall back to oc exec + cat
if ! oc cp "${OPERATOR_NAMESPACE}/${POD}:/tmp/e2e-cover" "${ARTIFACT_DIR}/coverage/" 2>/dev/null; then
    log "oc cp failed (tar may be missing), using oc exec fallback"
    for f in $(oc exec -n "${OPERATOR_NAMESPACE}" "${POD}" -- ls /tmp/e2e-cover/ 2>/dev/null); do
        oc exec -n "${OPERATOR_NAMESPACE}" "${POD}" -- cat "/tmp/e2e-cover/${f}" > "${ARTIFACT_DIR}/coverage/${f}" 2>/dev/null || true
    done
fi

# Check if we got any data
if [[ -z "$(ls -A "${ARTIFACT_DIR}/coverage/" 2>/dev/null)" ]]; then
    log "WARNING: No coverage data collected"
    exit 0
fi

log "Coverage data collected, generating reports"

# Convert to standard Go coverage profile
go tool covdata textfmt -i "${ARTIFACT_DIR}/coverage" -o "${ARTIFACT_DIR}/coverage.out" 2>/dev/null || true

if [[ ! -s "${ARTIFACT_DIR}/coverage.out" ]]; then
    log "WARNING: Could not convert coverage data to text format"
    exit 0
fi

# Generate per-function coverage text
go tool cover -func="${ARTIFACT_DIR}/coverage.out" > "${ARTIFACT_DIR}/coverage-func.txt" 2>/dev/null || true

# Generate JSON report for dashboard
go tool cover -func="${ARTIFACT_DIR}/coverage.out" 2>/dev/null | python3 -c "
import sys, json

lines = sys.stdin.readlines()
funcs = []
for line in lines[:-1]:
    parts = line.strip().rsplit(None, 1)
    if len(parts) == 2:
        file_func = parts[0].rsplit(None, 1)
        if len(file_func) == 2:
            funcs.append({
                'file': file_func[0].strip(),
                'function': file_func[1].strip().rstrip(':'),
                'coverage': parts[1]
            })
total = lines[-1].strip().split()[-1] if lines else '0%'
report = {
    'total_coverage': total,
    'operator': '${OPERATOR_NAME}',
    'function_count': len(funcs),
    'functions': funcs
}
with open('${ARTIFACT_DIR}/coverage-report.json', 'w') as f:
    json.dump(report, f, indent=2)
print(f'Total e2e coverage: {total}')
print(f'Functions covered: {len([f for f in funcs if f[\"coverage\"] != \"0.0%\"])} / {len(funcs)}')
" 2>/dev/null || true

# Generate HTML report for Prow artifact viewer
go tool cover -html="${ARTIFACT_DIR}/coverage.out" -o "${ARTIFACT_DIR}/coverage.html" 2>/dev/null || true

log "Coverage reports generated"
ls -la "${ARTIFACT_DIR}/coverage"* 2>/dev/null || true
