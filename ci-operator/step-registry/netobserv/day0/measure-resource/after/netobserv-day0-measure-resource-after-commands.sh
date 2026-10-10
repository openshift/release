#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Detect whether NetObserv is installed by checking for a Ready flowcollector.
if oc get flowcollector/cluster &>/dev/null 2>&1; then
    FC_READY=$(oc get flowcollector/cluster \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${FC_READY}" == "True" ]]; then
        NETOBSERV_ENABLED="true"
        MEASUREMENT_LABEL="with-netobserv"
    else
        echo "==> Flowcollector is not Ready; NetObserv may not be enabled, exiting!!!"
        exit 1
    fi
fi

# Determine job type
if [[ "${JOB_TYPE:-}" == "periodic" ]]; then
    DAY0_JOB_TYPE="periodic"
elif [[ "${JOB_NAME:-}" == *rehearse* ]]; then
    DAY0_JOB_TYPE="rehearse"
else
    DAY0_JOB_TYPE="${JOB_TYPE:-unknown}"
fi

echo "=== Day0 resource measurement ==="
echo "  NETOBSERV_ENABLED=${NETOBSERV_ENABLED}"
echo "  MEASUREMENT_LABEL=${MEASUREMENT_LABEL}"
echo "  DAY0_JOB_TYPE=${DAY0_JOB_TYPE}"

 # Suppress credential echo
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)
export ES_USERNAME ES_PASSWORD
if [[ "${WAS_TRACING}" == "true" ]]; then set -x; fi

export ES_INDEX="${ES_INDEX:-prod-netobserv-datapoints}"
export THANOS_VERIFY_CERTS="false"

echo "Waiting ${STABILIZATION_PERIOD}s for metrics to stabilize..."
sleep "${STABILIZATION_PERIOD}"

START_TIME=$(date +%s)
echo "Measurement window start: $(date -u -d "@${START_TIME}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${START_TIME}" '+%Y-%m-%dT%H:%M:%SZ')"

sleep "${MEASUREMENT_DURATION}"

END_TIME=$(date +%s)
echo "Measurement window end: $(date -u -d "@${END_TIME}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${END_TIME}" '+%Y-%m-%dT%H:%M:%SZ')"

# Download queries config
QUERIES_FILE="${ARTIFACT_DIR}/netobserv_prometheus_queries.yaml"
echo "Downloading queries config from ${QUERIES_CONFIG_URL}..."
curl -fsSL "${QUERIES_CONFIG_URL}" -o "${QUERIES_FILE}"

echo "Installing nope.py requirements..."
python -m pip install -q -r scripts/requirements.txt

UUID=$(python -c "import uuid; print(uuid.uuid4())")
echo "Run UUID: ${UUID}"

echo "${UUID}" > "${SHARED_DIR}/day0-uuid-${MEASUREMENT_LABEL}.txt"
echo "${BUILD_ID}" > "${SHARED_DIR}/day0-build-id.txt"

# Write all run metadata to a JSON file — nope.py reads and merges into ES doc
METADATA_FILE="${SHARED_DIR}/day0-metadata-${MEASUREMENT_LABEL}.json"
export NETOBSERV_ENABLED MEASUREMENT_LABEL DAY0_JOB_TYPE METADATA_FILE
python -c "
import json, os, re, subprocess
nodes = json.loads(subprocess.check_output(['oc', 'get', 'nodes', '-o', 'json'], text=True))['items']
version_output = subprocess.check_output([
    'oc', 'exec', '-n', os.environ.get('NETOBSERV_OPERATOR_NAMESPACE', 'netobserv-operator'),
    'deployment/netobserv-controller-manager', '-c', 'manager', '--', '/manager', '-v',
], text=True).strip()
version_match = re.search(r'build version: ([^,]+),', version_output)
if not version_match:
    raise ValueError(f'Cannot determine NetObserv build version from: {version_output}')
meta = {
    'netobserv_enabled': os.environ['NETOBSERV_ENABLED'] == 'true',
    'measurement_label': os.environ['MEASUREMENT_LABEL'],
    'build_id': os.environ.get('BUILD_ID', 'N/A'),
    'benchmark': 'netobserv-day0',
    'jobType': os.environ['DAY0_JOB_TYPE'],
    'job_name': os.environ.get('JOB_NAME', 'unknown'),
    'buildUrl': os.environ.get('BUILD_URL', 'unknown'),
    'nodeCount': len(nodes),
    'workerNodesCount': sum(
        'node-role.kubernetes.io/worker' in node.get('metadata', {}).get('labels', {})
        for node in nodes
    ),
    'netobserv_version': version_match.group(1).strip(),
}
with open(os.environ['METADATA_FILE'], 'w') as f:
    json.dump(meta, f, indent=2)
print('Metadata:', json.dumps(meta, indent=2))
"

python scripts/nope.py \
    --yaml-file "${QUERIES_FILE}" \
    --starttime "${START_TIME}" \
    --endtime "${END_TIME}" \
    --uuid "${UUID}" \
    --extra-metadata "${METADATA_FILE}"

echo "Copying artifacts..."
cp -r /tmp/data "${ARTIFACT_DIR}/day0-${MEASUREMENT_LABEL}" || true
cp /tmp/data/data_*.json "${SHARED_DIR}/day0-snapshot-${MEASUREMENT_LABEL}.json" 2>/dev/null || \
    echo "WARNING: no data snapshot found to persist for diff"
cp "${QUERIES_FILE}" "${ARTIFACT_DIR}/day0-queries-${MEASUREMENT_LABEL}.yaml" || true
cp "${METADATA_FILE}" "${ARTIFACT_DIR}/day0-metadata-${MEASUREMENT_LABEL}.json" || true
echo "${UUID}" > "${ARTIFACT_DIR}/day0-uuid-${MEASUREMENT_LABEL}.txt"
