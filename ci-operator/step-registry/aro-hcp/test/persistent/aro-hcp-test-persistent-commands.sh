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

# Disable tracing while service-principal credentials are read and used so the
# client-secret is never echoed into CI logs (xtrace would expand the traced
# `az login -p <secret>` line). Re-enabled immediately after authentication.
set +o xtrace
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
set -o xtrace

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

if [[ -n "${ARO_HCP_TEST_NAME:-}" ]]; then
  # Focused single-spec mode: run exactly one test by its exact name.  run-test
  # selects by name and writes JSON results to stdout (it has no --junit-path),
  # so pass/fail is conveyed by the exit code and the JSON is captured in the
  # build log.  ARO_HCP_SUITE_NAME is ignored in this mode.  Used by smoke jobs
  # such as the weekly single OpenShift 5 install.
  ./test/aro-hcp-tests run-test -n "${ARO_HCP_TEST_NAME}"
else
  ./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" --junit-path="${ARTIFACT_DIR}/junit.xml" --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" --max-concurrency 100
fi
