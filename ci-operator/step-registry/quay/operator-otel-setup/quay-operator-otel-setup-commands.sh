#!/bin/bash

set -euo pipefail

NS="openshift-operators"
PACKAGE="project-quay"
DEPLOY="quay-operator-tng"
CONTAINER="quay-operator"
SHARED_DIR="${SHARED_DIR:-/tmp/shared}"
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

if [[ ! -f "${SHARED_DIR}/jaeger_otlp_endpoint" ]]; then
  echo "Jaeger was not deployed; quay-operator tracing not configured"
  echo "tracing not configured: ${SHARED_DIR}/jaeger_otlp_endpoint absent" > "${ARTIFACT_DIR}/tracing-not-configured.txt"
  exit 0
fi
ENDPOINT=$(cat "${SHARED_DIR}/jaeger_otlp_endpoint")

# Patch the Subscription, not the Deployment: OLM reconciles the CSV's
# Deployment and would revert a direct env change.
SUBS=$(oc get subscriptions.operators.coreos.com -n "${NS}" -o json |
  jq -c --arg pkg "${PACKAGE}" '[.items[] | select(.spec.name == $pkg)]')
if [[ "$(jq length <<<"${SUBS}")" -ne 1 ]]; then
  echo "ERROR: expected exactly one Subscription for package ${PACKAGE} in ${NS}:" >&2
  oc get subscriptions.operators.coreos.com -n "${NS}" -o wide >&2 || true
  exit 1
fi
SUB=$(jq -r '.[0].metadata.name' <<<"${SUBS}")
CONFIG=$(jq -c --arg ep "${ENDPOINT}" '.[0].spec.config // {}
  | .env = ([(.env // [])[] | select(.name != "OTEL_EXPORTER_OTLP_ENDPOINT")]
            + [{name: "OTEL_EXPORTER_OTLP_ENDPOINT", value: $ep}])' <<<"${SUBS}")
echo "Setting OTEL_EXPORTER_OTLP_ENDPOINT=${ENDPOINT} on Subscription ${SUB}"
oc patch subscriptions.operators.coreos.com "${SUB}" -n "${NS}" --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/config\",\"value\":${CONFIG}}]"

echo "Waiting for ${DEPLOY} to carry the env..."
JSONPATH="{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].env[?(@.name==\"OTEL_EXPORTER_OTLP_ENDPOINT\")].value}"
for _ in $(seq 1 60); do
  [[ "$(oc get deployment "${DEPLOY}" -n "${NS}" -o jsonpath="${JSONPATH}")" == "${ENDPOINT}" ]] && break
  sleep 10
done
if [[ "$(oc get deployment "${DEPLOY}" -n "${NS}" -o jsonpath="${JSONPATH}")" != "${ENDPOINT}" ]]; then
  echo "ERROR: OLM did not propagate OTEL_EXPORTER_OTLP_ENDPOINT to ${DEPLOY} within 10m" >&2
  exit 1
fi
oc rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=10m

oc get deployment "${DEPLOY}" -n "${NS}" -o json |
  jq --arg c "${CONTAINER}" '.spec.template.spec.containers[] | select(.name == $c) | .env' \
  > "${ARTIFACT_DIR}/env-setup.json"

metrics_snapshot before
