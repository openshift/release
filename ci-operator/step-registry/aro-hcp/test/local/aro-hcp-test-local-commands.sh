#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"

unset GOFLAGS
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV=prow
export KUBECONFIG=kubeconfig

FRONTEND_ADDRESS=$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')
ADMIN_API_ADDRESS=$(kubectl get virtualservice -n aro-hcp-admin-api admin-api-vs -o jsonpath='{.spec.hosts[0]}')

az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
make frontend-grant-ingress DEPLOY_ENV=prow
az account set --subscription "${SUBSCRIPTION_ID}"

make e2e/local -o test/aro-hcp-tests SKIP_CERT_VERIFICATION=true FRONTEND_ADDRESS="https://${FRONTEND_ADDRESS}" ADMIN_API_ADDRESS="https://${ADMIN_API_ADDRESS}"

# the make target produces a junit.xml in ARTIFACT_DIR.  We want to copy to SHARED_DIR so we can create
# direct debugging links for the individual tests that failed. Gzip it due to 3mb SHARED_DIR limit.
gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e.xml.gz"
