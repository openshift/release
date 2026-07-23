#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"
export AZURE_TOKEN_CREDENTIALS=prod

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
    export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
    # Cross-tenant gating: slot-manager acquire resolves which mounted cluster
    # profile dir owns the leased subscription (its tenant + service principal)
    # and exports it as SELECTED_CLUSTER_PROFILE_DIR. Use it so a single job can
    # authenticate against subscriptions that live in different Azure tenants.
    if [[ -n "${SELECTED_CLUSTER_PROFILE_DIR:-}" ]]; then
        CLUSTER_PROFILE_DIR="${SELECTED_CLUSTER_PROFILE_DIR}"
    fi
else
    export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
fi

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" --junit-path="${ARTIFACT_DIR}/junit.xml" --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" --max-concurrency 100
