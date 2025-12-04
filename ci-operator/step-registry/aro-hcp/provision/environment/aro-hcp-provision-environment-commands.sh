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
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

unset GOFLAGS
make -o tooling/templatize/templatize entrypoint/Region TIMING_OUTPUT=${SHARED_DIR}/steps.yaml DEPLOY_ENV=prow ENTRYPOINT_JUNIT_OUTPUT=${ARTIFACT_DIR}/junit_entrypoint.xml	
