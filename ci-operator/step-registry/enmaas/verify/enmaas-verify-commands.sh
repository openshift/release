#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Verifying EnMaaS deployment health..."

echo "--- Waiting for deployments in namespace enmaas ---"
ENMAAS_DEPLOYS=$(oc get deployments -n enmaas -o jsonpath='{.items[*].metadata.name}')
if [[ -z "${ENMAAS_DEPLOYS}" ]]; then
  echo "ERROR: No deployments found in namespace enmaas."
  exit 1
fi
for deploy in ${ENMAAS_DEPLOYS}; do
  echo "Waiting for deployment/${deploy} in enmaas..."
  oc rollout status "deployment/${deploy}" -n enmaas --timeout="${VERIFY_TIMEOUT}"
done

echo "--- Waiting for deployments in namespace enmaas-monitoring ---"
MONITORING_DEPLOYS=$(oc get deployments -n enmaas-monitoring -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [[ -z "${MONITORING_DEPLOYS}" ]]; then
  echo "ERROR: No deployments found in namespace enmaas-monitoring."
  exit 1
fi
for deploy in ${MONITORING_DEPLOYS}; do
  echo "Waiting for deployment/${deploy} in enmaas-monitoring..."
  oc rollout status "deployment/${deploy}" -n enmaas-monitoring --timeout="${VERIFY_TIMEOUT}"
done

echo "--- Checking CloudNativePG cluster health ---"
if ! oc -n enmaas wait --for=condition=Ready cluster.postgresql.cnpg.io/aigateway-pg --timeout="${VERIFY_TIMEOUT}"; then
  echo "ERROR: CloudNativePG cluster aigateway-pg not found or not Ready."
  exit 1
fi

echo "--- Checking PVC status ---"
PVC_STATUS=$(oc get pvc -n enmaas -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
if [[ -n "${PVC_STATUS}" ]]; then
  echo "${PVC_STATUS}"
  NOT_BOUND=$(echo "${PVC_STATUS}" | grep -v Bound || true)
  if [[ -n "${NOT_BOUND}" ]]; then
    echo "ERROR: Some PVCs are not in Bound state:"
    echo "${NOT_BOUND}"
    exit 1
  else
    echo "All PVCs are Bound."
  fi
else
  echo "No PVCs found in enmaas namespace."
fi

echo "--- Checking Routes ---"
oc -n enmaas get routes || echo "No routes found in enmaas namespace."

echo "--- Validating required routes ---"
MISSING_ROUTES=0
for REQUIRED_ROUTE in dashboard-enmaas gateway-enmaas; do
  if oc -n enmaas get route "${REQUIRED_ROUTE}" > /dev/null 2>&1; then
    echo "Route ${REQUIRED_ROUTE} exists."
  else
    echo "ERROR: Required route ${REQUIRED_ROUTE} not found in namespace enmaas."
    MISSING_ROUTES=1
  fi
done
if [[ "${MISSING_ROUTES}" -ne 0 ]]; then
  echo "ERROR: One or more required routes are missing."
  exit 1
fi

echo "--- Deployment Summary ---"
echo "Namespace: enmaas"
oc get deployments -n enmaas 2>/dev/null || true
oc get statefulsets -n enmaas 2>/dev/null || true
oc get pods -n enmaas 2>/dev/null || true

echo ""
echo "Namespace: enmaas-monitoring"
oc get deployments -n enmaas-monitoring 2>/dev/null || true
oc get pods -n enmaas-monitoring 2>/dev/null || true

echo "EnMaaS deployment verification complete."
