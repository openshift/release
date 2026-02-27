#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

if [[ "${ARO_HCP_OPENSHIFT_CHANNEL_GROUP:-}"  =~ "candidate-" ]]; then
  candidate_version="$(
    curl -s "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${ARO_HCP_OPENSHIFT_CHANNEL_GROUP}" \
      | jq -r '.nodes[].version' \
      | sort -V \
      | tail -n1
  )"

  if [[ -z "${candidate_version}" || "${candidate_version}" == "null" ]]; then
    echo "Failed to resolve ${ARO_HCP_OPENSHIFT_CHANNEL_GROUP} version from upgrades info graph." >&2
    exit 1
  fi

  export ARO_HCP_OPENSHIFT_CONTROLPLANE_VERSION="${candidate_version}"
  export ARO_HCP_OPENSHIFT_NODEPOOL_VERSION="${candidate_version}"
  # Channel group name is just "candidate", with no version number, so we need to set it back to "candidate"
  export ARO_HCP_OPENSHIFT_CHANNEL_GROUP="candidate"
  export ARO_HCP_OPENSHIFT_NODEPOOL_CHANNEL_GROUP="candidate"
fi

./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" --junit-path="${ARTIFACT_DIR}/junit.xml" --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" --max-concurrency 100
