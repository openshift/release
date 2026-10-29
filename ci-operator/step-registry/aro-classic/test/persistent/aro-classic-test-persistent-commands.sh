#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export AZURE_SUBSCRIPTION_ID; AZURE_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

AZURE_FP_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/fp-client-id")
export AZURE_FP_SERVICE_PRINCIPAL_ID; AZURE_FP_SERVICE_PRINCIPAL_ID=$(az ad sp show --id "${AZURE_FP_CLIENT_ID}" --query "id" -o tsv)

export LOCATION; LOCATION="${LOCATION:=${LEASED_RESOURCE}}"
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

export E2E_TYPE; E2E_TYPE="${E2E_TYPE:=both}"

run_e2e() {
  local type="$1"
  export RESOURCEGROUP="${NAMESPACE}-prow-${LOCATION}-${UNIQUE_HASH}-${type}"
  export CLUSTER="${RESOURCEGROUP}"
  if [[ "${type}" == "miwi" ]]; then
    export USE_WI="true"
    export PLATFORM_WORKLOAD_IDENTITY_ROLE_SETS; PLATFORM_WORKLOAD_IDENTITY_ROLE_SETS=$(az rest --method GET --uri "/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.redhatopenshift/locations/${LOCATION}/platformworkloadidentityrolesets?api-version=2025-07-25" --query "value[*].properties")
  else
    export USE_WI="false"
  fi
  e2e.test -test.v --ginkgo.v --ginkgo.timeout 180m --ginkgo.flake-attempts=2 --ginkgo.no-color --ginkgo.label-filter=!smoke
}

if [[ "${E2E_TYPE}" == "both" ]]; then
  run_e2e miwi >"${ARTIFACT_DIR}/miwi.log" 2>&1 &
  PID_MIWI=$!
  run_e2e csp >"${ARTIFACT_DIR}/csp.log" 2>&1 &
  PID_CSP=$!

  RC_MIWI=0
  RC_CSP=0
  wait $PID_MIWI || RC_MIWI=$?
  wait $PID_CSP || RC_CSP=$?

  set +o xtrace
  echo "=== miwi log ==="
  cat "${ARTIFACT_DIR}/miwi.log"
  echo "=== csp log ==="
  cat "${ARTIFACT_DIR}/csp.log"

  [[ $RC_MIWI -ne 0 ]] && echo "=== miwi run failed ===" >&2
  [[ $RC_CSP -ne 0 ]] && echo "=== csp run failed ===" >&2

  [[ $RC_MIWI -eq 0 && $RC_CSP -eq 0 ]]
elif [[ "${E2E_TYPE}" == "miwi" ]]; then
  run_e2e miwi
elif [[ "${E2E_TYPE}" == "csp" ]]; then
  run_e2e csp
else
  echo "Invalid E2E_TYPE: ${E2E_TYPE}" >&2
  exit 1
fi