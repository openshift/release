#!/bin/bash

set -euo pipefail

# Fail-fast preflight: ensure Sail/Istio can program a Gateway (class istio) before
# spending time on Kuadrant install + the full testsuite. On failure, dump
# diagnostics to ARTIFACT_DIR so they survive post-phase cluster cleanup.

PROBE_NS="${GATEWAY_PROBE_NAMESPACE}"
PROBE_NAME="${GATEWAY_PROBE_NAME}"
GATEWAY_CLASS="${GATEWAY_PROBE_CLASS}"
DUMP_DIR="${ARTIFACT_DIR}/gateway-probe"
WAIT_SECONDS="${GATEWAY_PROBE_TIMEOUT_SECONDS}"

mkdir -p "${DUMP_DIR}"

dump_gateway_probe_diagnostics() {
  echo "=== Dumping gateway probe diagnostics to ${DUMP_DIR} ===" >&2

  {
    echo "# GatewayClasses"
    oc get gatewayclass -o wide 2>&1 || true
    echo
    oc get gatewayclass -o yaml 2>&1 || true
  } > "${DUMP_DIR}/gatewayclass.yaml" || true

  {
    echo "# Probe Gateway"
    oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o wide 2>&1 || true
    echo
    oc describe gateway "${PROBE_NAME}" -n "${PROBE_NS}" 2>&1 || true
    echo
    oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o yaml 2>&1 || true
  } > "${DUMP_DIR}/gateway.yaml" || true

  {
    echo "# Istio / IstioCNI"
    oc get istio,istiocni -A -o wide 2>&1 || true
    echo
    oc get istio,istiocni -A -o yaml 2>&1 || true
  } > "${DUMP_DIR}/istio.yaml" || true

  {
    echo "# Dataplane in ${PROBE_NS}"
    oc get deploy,svc,endpoints,pods -n "${PROBE_NS}" -o wide 2>&1 || true
    echo
    oc describe deploy,svc,pods -n "${PROBE_NS}" 2>&1 || true
    echo
    oc get events -n "${PROBE_NS}" --sort-by='.lastTimestamp' 2>&1 || true
  } > "${DUMP_DIR}/probe-namespace.yaml" || true

  for ns in openshift-operators istio-system istio-cni; do
    {
      echo "# Pods / deployments in ${ns}"
      oc get deploy,pods,svc -n "${ns}" -o wide 2>&1 || true
    } > "${DUMP_DIR}/${ns}-workloads.txt" || true
  done

  # istiod logs (best effort across common namespaces)
  for ns in openshift-operators istio-system; do
    istiod="$(oc get pods -n "${ns}" -l app=istiod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${istiod}" ]]; then
      oc logs -n "${ns}" "${istiod}" --tail=500 > "${DUMP_DIR}/istiod-${ns}.log" 2>&1 || true
    fi
  done

  {
    echo "# Recent cluster events mentioning gateway / istio"
    oc get events -A --sort-by='.lastTimestamp' 2>&1 | grep -Ei 'gateway|istio|sail|AddressNotAssigned|Failed' | tail -200 || true
  } > "${DUMP_DIR}/events-filtered.txt" || true

  echo "=== Gateway probe summary ===" >&2
  oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o yaml 2>&1 | tee "${DUMP_DIR}/gateway-final.yaml" >&2 || true
  oc get deploy,svc,pods -n "${PROBE_NS}" -o wide 2>&1 | tee "${DUMP_DIR}/probe-workloads-final.txt" >&2 || true
}

is_gateway_programmed() {
  local status
  status="$(oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

echo "=== Ensuring GatewayClass ${GATEWAY_CLASS} exists ==="
if ! oc get gatewayclass "${GATEWAY_CLASS}" >/dev/null 2>&1; then
  echo "ERROR: GatewayClass ${GATEWAY_CLASS} not found. Available:" >&2
  oc get gatewayclass -o wide >&2 || true
  dump_gateway_probe_diagnostics
  exit 1
fi
oc get gatewayclass -o wide

echo "=== Creating probe namespace ${PROBE_NS} ==="
oc get ns "${PROBE_NS}" >/dev/null 2>&1 || oc create ns "${PROBE_NS}"

echo "=== Creating probe Gateway ${PROBE_NS}/${PROBE_NAME} (class ${GATEWAY_CLASS}) ==="
cat <<EOF | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${PROBE_NAME}
  namespace: ${PROBE_NS}
  labels:
    kuadrant.s390x.ci/probe: "true"
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

echo "=== Waiting up to ${WAIT_SECONDS}s for Gateway Programmed=True ==="
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  if is_gateway_programmed; then
    echo "Gateway ${PROBE_NS}/${PROBE_NAME} is Programmed=True"
    oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o wide
    echo "=== Cleaning up probe Gateway ==="
    oc delete gateway "${PROBE_NAME}" -n "${PROBE_NS}" --ignore-not-found=true --wait=false
    oc delete ns "${PROBE_NS}" --ignore-not-found=true --wait=false
    echo "=== Gateway probe succeeded ==="
    exit 0
  fi

  accepted="$(oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o jsonpath='{range .status.conditions[?(@.type=="Accepted")]}{.status}{end}' 2>/dev/null || true)"
  programmed="$(oc get gateway "${PROBE_NAME}" -n "${PROBE_NS}" -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{.message}{end}' 2>/dev/null || true)"
  echo "  Accepted=${accepted:-<?>} Programmed=${programmed:-<?>}"
  sleep 15
done

echo "ERROR: Gateway ${PROBE_NS}/${PROBE_NAME} did not become Programmed within ${WAIT_SECONDS}s" >&2
dump_gateway_probe_diagnostics
# Leave the probe Gateway in place for any late gather steps; cleanup removes the namespace/cluster.
exit 1
