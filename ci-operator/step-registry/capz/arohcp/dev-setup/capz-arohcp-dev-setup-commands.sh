#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

{ set +o xtrace; } 2>/dev/null
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"

# Source slot-manager env to get CUSTOMER_SUBSCRIPTION (shard subscription).
# This mirrors the pattern used in aro-hcp-test-local.
env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${env_file}"
else
  export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
fi

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

unset GOFLAGS

# This block prepares the environment to run the tests in.
# It runs against INFRA_SUBSCRIPTION.
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
export AZURE_TOKEN_CREDENTIALS=prod
FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
# Capture the SVC resource group from the frontend-grant-ingress output
SVC_NSG_RG=$(make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}" 2>&1 | tee /dev/stderr | grep -oP '"resourceGroup":\s*"\K[^"]+' | head -1)

# Grant ingress from the AKS management cluster's outbound IP,
# so the aro-mockup-proxy running inside it can reach the DEV RP frontend.
# The AKS cluster lives in the slot-manager-assigned subscription, the NSG in INFRA_SUBSCRIPTION.
if [[ -n "${SVC_NSG_RG}" && -f "${SHARED_DIR}/resourcegroup_aks" && -f "${SHARED_DIR}/cluster-name" ]]; then
  AKS_RG=$(cat "${SHARED_DIR}/resourcegroup_aks")
  AKS_NAME=$(cat "${SHARED_DIR}/cluster-name")
  az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
  AKS_PIP_ID=$(az aks show -g "${AKS_RG}" -n "${AKS_NAME}" \
    --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[0].id" -o tsv)
  AKS_OUTBOUND_IP=$(az network public-ip show --ids "${AKS_PIP_ID}" --query "ipAddress" -o tsv)
  az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
  echo "AKS management cluster outbound IP: ${AKS_OUTBOUND_IP}"
  echo "SVC NSG resource group: ${SVC_NSG_RG}"
  az network nsg rule create \
    --resource-group "${SVC_NSG_RG}" \
    --nsg-name "svc-cluster-node-nsg" \
    --name "allow-istio-ingress-aks-mgmt" \
    --access Allow --protocol Tcp --direction Inbound \
    --source-address-prefix "${AKS_OUTBOUND_IP}" \
    --source-port-range "*" --destination-address-prefix "*" \
    --destination-port-range "443" --priority 1001
  echo "NSG rule added for AKS management cluster IP: ${AKS_OUTBOUND_IP}"
fi

# This block runs against CUSTOMER_SUBSCRIPTION.
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

# Write frontend address for subsequent CAPZ test steps
echo "${FRONTEND_ADDRESS}" > "${SHARED_DIR}/dev_endpoint"
