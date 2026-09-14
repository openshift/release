#!/bin/bash

set -o nounset
set -o pipefail

# Collect Quay's OTLP traces from the in-cluster Jaeger. Runs in post, so it
# gathers on both pass and fail. Best-effort throughout: every command tolerates
# failure and the script always exits 0 so it never fails the run.

QUAY_NS="${QUAYNAMESPACE:-quay-enterprise}"
SHARED_DIR="${SHARED_DIR:-/tmp/shared}"
JAEGER_TRACE_LIMIT="${JAEGER_TRACE_LIMIT:-5000}"
JAEGER_WINDOW="${JAEGER_WINDOW:-5m}"
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

# Export the collected traces in time windows rather than one request. A single
# /api/traces?limit=50000 serialized the whole in-memory store into one response
# and OOM-killed Jaeger (deploy limit hit, curl dropped with zero bytes). Instead
# bound each query with start/end (MICROSECONDS since epoch): step from the
# recorded Jaeger deploy time to now in JAEGER_WINDOW slices, limit per window.
# Record each window's HTTP status and keep its per-window .response file on a
# non-2xx so a failed query stays debuggable next run.
NOW=$(date +%s)
START=$(cat "${SHARED_DIR}/jaeger_deployed" 2>/dev/null || echo "")
if ! [[ "${START}" =~ ^[0-9]+$ ]]; then
  # Older deploy step wrote "true"; fall back to a one-hour lookback window.
  START=$((NOW - 3600))
fi

# Parse JAEGER_WINDOW into seconds, accepting a plain number or an h/m/s suffix.
# Validate the numeric part before any arithmetic so a bad value can't abort the
# step under nounset; fall back to 5m.
WNUM="${JAEGER_WINDOW%[hms]}"
WUNIT="${JAEGER_WINDOW#"${WNUM}"}"
if [[ "${WNUM}" =~ ^[0-9]+$ ]]; then
  case "${WUNIT}" in
    h) WINDOW_SECS=$(( WNUM * 3600 )) ;;
    m) WINDOW_SECS=$(( WNUM * 60 )) ;;
    *) WINDOW_SECS=$(( WNUM )) ;;
  esac
else
  WINDOW_SECS=300
fi
[[ "${WINDOW_SECS}" -gt 0 ]] || WINDOW_SECS=300

TOTAL_TRACES=0
TOTAL_SPANS=0
IDX=0
WS="${START}"
while [[ "${WS}" -lt "${NOW}" ]]; do
  WE=$(( WS + WINDOW_SECS ))
  [[ "${WE}" -gt "${NOW}" ]] && WE="${NOW}"
  IDX=$(( IDX + 1 ))
  RESP="${OUT}/traces-${IDX}.response"
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 120 \
    "http://127.0.0.1:16686/api/traces?service=quay&limit=${JAEGER_TRACE_LIMIT}&start=$(( WS * 1000000 ))&end=$(( WE * 1000000 ))" \
    -o "${RESP}" -w '%{http_code}' 2>/dev/null || echo "000")
  if [[ "${HTTP_CODE}" == 2* ]] && jq -e '.data' "${RESP}" >/dev/null 2>&1; then
    TC=$(jq '.data | length' "${RESP}" 2>/dev/null || echo 0)
    SC=$(jq '[.data[].spans | length] | add // 0' "${RESP}" 2>/dev/null || echo 0)
    mv "${RESP}" "${OUT}/traces-${IDX}.json"
    TOTAL_TRACES=$(( TOTAL_TRACES + TC ))
    TOTAL_SPANS=$(( TOTAL_SPANS + SC ))
    echo "window ${IDX}: HTTP ${HTTP_CODE}, ${TC} traces"
  else
    echo "WARNING: window ${IDX}: HTTP ${HTTP_CODE}; response kept at ${RESP} for debugging" >&2
  fi
  WS="${WE}"
done

echo "Collected ${TOTAL_TRACES} traces / ${TOTAL_SPANS} spans for service quay across ${IDX} windows"
gzip -f "${OUT}"/traces-*.json 2>/dev/null || true

exit 0
