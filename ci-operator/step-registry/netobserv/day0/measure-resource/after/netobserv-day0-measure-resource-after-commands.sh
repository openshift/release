#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Detect whether NetObserv is installed by checking for a Ready flowcollector.
# This allows the same step to be called twice in the pipeline — once before
# netobserv-day0-patch-cno (baseline) and once after (with NetObserv) — without
# needing separate step definitions.
if oc get flowcollector/cluster &>/dev/null 2>&1; then
    FC_READY=$(oc get flowcollector/cluster \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${FC_READY}" == "True" ]]; then
        NETOBSERV_ENABLED="true"
        MEASUREMENT_LABEL="with-netobserv"
    else
        # FlowCollector exists but not Ready — treat as not-yet-installed
        NETOBSERV_ENABLED="false"
        MEASUREMENT_LABEL="without-netobserv"
    fi
else
    NETOBSERV_ENABLED="false"
    MEASUREMENT_LABEL="without-netobserv"
fi

echo "=== Day0 resource measurement ==="
echo "  NETOBSERV_ENABLED=${NETOBSERV_ENABLED}"
echo "  MEASUREMENT_LABEL=${MEASUREMENT_LABEL}"

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
QUERIES_FILE="${ARTIFACT_DIR}/day0_prometheus_queries.yaml"
echo "Downloading queries config from ${QUERIES_CONFIG_URL}..."
curl -fsSL "${QUERIES_CONFIG_URL}" -o "${QUERIES_FILE}"

# Install nope.py dependencies
echo "Installing nope.py requirements..."
python3 -m pip install -q -r scripts/requirements.txt

UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
echo "Run UUID: ${UUID}"

# Persist UUID and shared build ID for the with-netobserv measurement to reuse
echo "${UUID}" > "${SHARED_DIR}/day0-uuid-${MEASUREMENT_LABEL}.txt"
echo "${BUILD_ID}" > "${SHARED_DIR}/day0-build-id.txt"

python3 scripts/nope.py \
    --yaml-file "${QUERIES_FILE}" \
    --starttime "${START_TIME}" \
    --endtime "${END_TIME}" \
    --uuid "${UUID}" \
    --build-id "${BUILD_ID}" \
    --netobserv-enabled "${NETOBSERV_ENABLED}" \
    --measurement-label "${MEASUREMENT_LABEL}" \
    --benchmark "netobserv-day0"

echo "Copying artifacts..."
cp -r /tmp/data "${ARTIFACT_DIR}/day0-${MEASUREMENT_LABEL}" || true

# Persist the latest data snapshot to SHARED_DIR so the diff-resource step can compare
# without and with measurements within the same run.
cp /tmp/data/data_*.json "${SHARED_DIR}/day0-snapshot-${MEASUREMENT_LABEL}.json" 2>/dev/null || \
    echo "WARNING: no data snapshot found to persist for diff"
cp "${QUERIES_FILE}" "${ARTIFACT_DIR}/day0-queries-${MEASUREMENT_LABEL}.yaml" || true
echo "${UUID}" > "${ARTIFACT_DIR}/day0-uuid-${MEASUREMENT_LABEL}.txt"
cat > "${ARTIFACT_DIR}/day0-run-info-${MEASUREMENT_LABEL}.txt" <<EOF
build_id=${BUILD_ID}
measurement_label=${MEASUREMENT_LABEL}
netobserv_enabled=${NETOBSERV_ENABLED}
start_time=${START_TIME}
end_time=${END_TIME}
EOF
