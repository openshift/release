#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Verifying EnMaaS deployment health..."
VERIFY_EXIT_CODE=0
DEADLINE=$((SECONDS + 1800))

verify_oc() {
  local remaining=$((DEADLINE - SECONDS)) request_timeout=30s argument
  if ((remaining <= 0)); then
    echo "ERROR: Verification exceeded its 30-minute deadline." >&2
    return 1
  fi
  for argument in "$@"; do
    if [[ "${argument}" == --timeout=* ]]; then
      request_timeout="${argument#--timeout=}"
    fi
  done
  timeout --kill-after=5s "${remaining}s" oc --request-timeout="${request_timeout}" "$@"
}

record_failure() {
  local status="$1"
  shift
  echo "ERROR: $*"
  if ((VERIFY_EXIT_CODE == 0)); then
    VERIFY_EXIT_CODE=${status}
  fi
}

declare -A DEPLOYMENTS
for namespace in enmaas enmaas-monitoring; do
  if names=$(verify_oc get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}'); then
    DEPLOYMENTS[${namespace}]="${names}"
    if [[ -z "${names}" ]]; then
      record_failure 1 "No deployments found in namespace ${namespace}."
    fi
  else
    record_failure "$?" "Failed to list deployments in namespace ${namespace}."
  fi
done
for namespace in enmaas enmaas-monitoring; do
  for deploy in ${DEPLOYMENTS[${namespace}]:-}; do
    echo "Waiting for deployment/${deploy} in ${namespace}..."
    if verify_oc rollout status "deployment/${deploy}" -n "${namespace}" --timeout="${VERIFY_TIMEOUT}"; then
      echo "Ready: ${namespace}/deployment/${deploy}."
    else
      record_failure "$?" "Rollout failed: ${namespace}/deployment/${deploy}."
    fi
  done
done

echo "--- Checking CloudNativePG cluster health ---"
if verify_oc -n enmaas wait --for=condition=Ready cluster.postgresql.cnpg.io/aigateway-pg --timeout="${VERIFY_TIMEOUT}"; then
  echo "CloudNativePG cluster aigateway-pg is Ready."
else
  record_failure "$?" "CloudNativePG cluster aigateway-pg not found or not Ready."
fi

echo "--- Checking PVC status ---"
if PVC_STATUS=$(verify_oc get pvc -n enmaas -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'); then
  if [[ -n "${PVC_STATUS}" ]]; then
    while IFS=$'\t' read -r name phase; do
      if [[ "${phase}" != Bound ]]; then
        record_failure 1 "PVC ${name} is ${phase}, not Bound."
      else
        echo "PVC ${name} is Bound."
      fi
    done <<< "${PVC_STATUS}"
  else
    echo "No PVCs found in enmaas namespace."
  fi
else
  record_failure "$?" "Failed to list PVCs in namespace enmaas."
fi

echo "--- Checking Routes ---"
if ! verify_oc -n enmaas get routes; then
  echo "WARNING: Could not list routes in enmaas namespace."
fi

echo "--- Validating required routes ---"
for REQUIRED_ROUTE in dashboard-enmaas gateway-enmaas; do
  if verify_oc -n enmaas get route "${REQUIRED_ROUTE}" > /dev/null; then
    echo "Route ${REQUIRED_ROUTE} exists."
  else
    record_failure "$?" "Required route ${REQUIRED_ROUTE} unavailable in namespace enmaas."
  fi
done

echo "--- Deployment Summary ---"
for namespace in enmaas enmaas-monitoring; do
  echo "Namespace: ${namespace}"
  for resource in deployments statefulsets pods; do
    if ! verify_oc get "${resource}" -n "${namespace}"; then
      echo "WARNING: Could not summarize ${resource} in ${namespace}."
    fi
  done
done

if ((VERIFY_EXIT_CODE == 0)); then
  echo "EnMaaS deployment verification complete."
else
  echo "ERROR: EnMaaS deployment verification failed; see check results above."
fi
exit "${VERIFY_EXIT_CODE}"
