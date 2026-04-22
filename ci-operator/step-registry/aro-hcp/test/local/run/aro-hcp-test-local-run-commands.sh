#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${INFRA_SHARD}-subscription-id")
export DEPLOY_ENV="prow"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"

# TODO: Remove kubeconfig setup once exporter_metrics.go no longer requires direct svc cluster access.
unset GOFLAGS
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
export AZURE_TOKEN_CREDENTIALS=prod

az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/run -o test/aro-hcp-tests \
  FRONTEND_ADDRESS="$(cat "${SHARED_DIR}/frontend-address")" \
  ADMIN_API_ADDRESS="$(cat "${SHARED_DIR}/admin-api-address")" \
  SKIP_CERT_VERIFICATION=true

# the make target produces a junit.xml in ARTIFACT_DIR.  We want to copy to SHARED_DIR so we can create
# direct debugging links for the individual tests that failed. Gzip it due to 3mb SHARED_DIR limit.
gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e.xml.gz"
