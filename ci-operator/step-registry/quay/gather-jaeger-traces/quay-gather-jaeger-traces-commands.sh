#!/bin/bash

set -o nounset
set -o pipefail

# Collect Quay's OTLP traces from the in-cluster Jaeger. Runs in post, so it
# gathers on both pass and fail. Best-effort throughout: every command tolerates
# failure and the script always exits 0 so it never fails the run.

QUAY_NS="${QUAYNAMESPACE:-quay-enterprise}"
SHARED_DIR="${SHARED_DIR:-/tmp/shared}"
JAEGER_LOOKBACK="${JAEGER_LOOKBACK:-6h}"
JAEGER_TRACE_LIMIT="${JAEGER_TRACE_LIMIT:-50000}"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
OUT="${ARTIFACT_DIR}/jaeger-traces"
mkdir -p "${OUT}"

if [[ ! -f "${SHARED_DIR}/jaeger_deployed" ]]; then
  echo "Jaeger was not deployed; nothing to gather"
  exit 0
fi

oc get pods -n "${QUAY_NS}" -l app=jaeger -o wide > "${OUT}/jaeger-pods.txt" 2>&1 || true
oc logs deploy/jaeger -n "${QUAY_NS}" > "${OUT}/jaeger.log" 2>&1 || true

oc port-forward -n "${QUAY_NS}" svc/jaeger 16686:16686 > "${OUT}/port-forward.log" 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

READY=false
for _ in $(seq 1 12); do
  if curl -sf --connect-timeout 5 --max-time 10 "http://127.0.0.1:16686/api/services" -o "${OUT}/services.json"; then
    READY=true
    break
  fi
  sleep 5
done

if [[ "${READY}" != "true" ]]; then
  echo "WARNING: Jaeger query API never became reachable; keeping logs for debugging" >&2
  exit 0
fi

curl -sf --connect-timeout 5 --max-time 300 "http://127.0.0.1:16686/api/traces?service=quay&limit=${JAEGER_TRACE_LIMIT}&lookback=${JAEGER_LOOKBACK}" \
  -o "${OUT}/traces.json" || true

if [[ -s "${OUT}/traces.json" ]] && jq -e '.data' "${OUT}/traces.json" >/dev/null 2>&1; then
  TRACE_COUNT=$(jq '.data | length' "${OUT}/traces.json" 2>/dev/null || echo "?")
  SPAN_COUNT=$(jq '[.data[].spans | length] | add // 0' "${OUT}/traces.json" 2>/dev/null || echo "?")
  echo "Collected ${TRACE_COUNT} traces / ${SPAN_COUNT} spans for service quay"
  gzip -f "${OUT}/traces.json" || true
else
  echo "WARNING: no usable traces collected; keeping whatever was written for debugging" >&2
fi

exit 0
