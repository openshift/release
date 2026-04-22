#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${INFRA_SHARD}-subscription-id")
export DEPLOY_ENV="prow"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"

unset GOFLAGS
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
export AZURE_TOKEN_CREDENTIALS=prod

FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
ADMIN_API_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp-admin-api admin-api-vs -o jsonpath='{.spec.hosts[0]}')"

make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

echo "${FRONTEND_ADDRESS}" > "${SHARED_DIR}/frontend-address"
echo "${ADMIN_API_ADDRESS}" > "${SHARED_DIR}/admin-api-address"
