#!/bin/bash

set -o nounset
set -o pipefail

# Best-effort throughout: always exits 0 so it never fails the run.

NS="openshift-operators"
DEPLOY="quay-operator-tng"
CONTAINER="quay-operator"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# Best-effort: write metrics-<phase>.txt, or metrics-<phase>.unavailable with the
# reason. Port 8080 is controller-runtime's metrics listener; the operator
# Service targets 7071, so forward to the pod directly.
PF_PID=""
trap '[[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true' EXIT
metrics_snapshot() {
  local phase=$1 out="${ARTIFACT_DIR}/operator-metrics" pod
  mkdir -p "${out}"
  pod=$(oc get pods -n "${NS}" -l name=quay-operator-alm-owned -o json 2>/dev/null |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")][0].metadata.name // empty' || true)
  if [[ -z "${pod}" ]]; then
    echo "no running quay-operator pod in ${NS}" > "${out}/metrics-${phase}.unavailable"
    return 0
  fi
  oc port-forward -n "${NS}" "pod/${pod}" 18080:8080 > "${out}/port-forward-${phase}.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 10); do
    curl -sf --connect-timeout 5 --max-time 30 http://127.0.0.1:18080/metrics -o "${out}/metrics-${phase}.txt" && break
    rm -f "${out}/metrics-${phase}.txt"
    sleep 3
  done
  kill "${PF_PID}" 2>/dev/null || true
  PF_PID=""
  [[ -s "${out}/metrics-${phase}.txt" ]] || echo "GET :8080/metrics on pod ${pod} failed" > "${out}/metrics-${phase}.unavailable"
}

# OLM-revert check: the env set by quay-operator-otel-setup must survive the tests.
oc get deployment "${DEPLOY}" -n "${NS}" -o json 2>/dev/null |
  jq --arg c "${CONTAINER}" '.spec.template.spec.containers[] | select(.name == $c) | .env' \
  > "${ARTIFACT_DIR}/env-after.txt" || true
if jq -e 'any(.[]?; .name == "OTEL_EXPORTER_OTLP_ENDPOINT")' "${ARTIFACT_DIR}/env-after.txt" >/dev/null 2>&1; then
  echo "PASS: OTEL_EXPORTER_OTLP_ENDPOINT still set on ${DEPLOY}/${CONTAINER}"
else
  echo "FAIL: OTEL_EXPORTER_OTLP_ENDPOINT missing from ${DEPLOY}/${CONTAINER}"
fi

metrics_snapshot after

exit 0
