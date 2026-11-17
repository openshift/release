#!/bin/bash
set -euo pipefail

OPERATOR_NAMESPACE="openshift-kube-descheduler-operator"
PACKAGE_NAME="cluster-kube-descheduler-operator"
OPERATOR_DEPLOYMENT="descheduler-operator"
OPERAND_DEPLOYMENT="descheduler"

echo "=== Post-upgrade verification ==="
oc get deployments -n "${OPERATOR_NAMESPACE}" -o wide
oc get pods -n "${OPERATOR_NAMESPACE}" -o wide

POST_CSV=$(oc get subscription "${PACKAGE_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
if [ -z "${POST_CSV}" ]; then
  echo "ERROR: No CSV found in ${OPERATOR_NAMESPACE} after upgrade"
  oc get subscription,installplan -n "${OPERATOR_NAMESPACE}" -o yaml || true
  exit 1
fi
POST_PHASE=$(oc get csv "${POST_CSV}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "${POST_PHASE}" != "Succeeded" ]; then
  echo "ERROR: CSV ${POST_CSV} phase is ${POST_PHASE} after upgrade"
  exit 1
fi
if [ -f "${SHARED_DIR}/pre-upgrade-csv" ]; then
  echo "Pre-upgrade CSV: $(cat "${SHARED_DIR}/pre-upgrade-csv")"
fi
echo "Post-upgrade CSV: ${POST_CSV} (${POST_PHASE})"

for name in "${OPERATOR_DEPLOYMENT}" "${OPERAND_DEPLOYMENT}"; do
  echo "Waiting for deployment/${name} to be running after upgrade..."
  for i in $(seq 1 30); do
    READY=$(oc get deployment "${name}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${READY}" -ge 1 ] 2>/dev/null; then
      oc wait "deployment/${name}" -n "${OPERATOR_NAMESPACE}" --for=condition=Available --timeout=300s
      echo "deployment/${name} is running with ${READY} ready replica(s) after upgrade"
      break
    fi
    if [ "${i}" -eq 30 ]; then
      echo "ERROR: Timed out waiting for deployment/${name} after upgrade"
      oc get deployments -n "${OPERATOR_NAMESPACE}" -o wide || true
      oc get pods -n "${OPERATOR_NAMESPACE}" -o wide || true
      exit 1
    fi
    echo "Waiting for deployment/${name} after upgrade... (${i}/30)"
    sleep 10
  done
done

echo "=== Running descheduler e2e tests ==="
SKIP_OPERATOR_INSTALL=true go test -v -timeout 3h -count 1 ./test/e2e/...
