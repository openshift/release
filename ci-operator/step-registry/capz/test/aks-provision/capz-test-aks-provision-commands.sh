#!/usr/bin/env bash
set -euo pipefail

source openshift-ci/capz-test-env.sh

AZURE_LOCATION="${LOCATION}"

{ set +o xtrace; } 2>/dev/null
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-capz-rg"
CLUSTER="${RESOURCE_NAME_PREFIX}-capz-aks"

echo "Creating resource group ${RESOURCEGROUP}"
az group create --name "${RESOURCEGROUP}" --location "${AZURE_LOCATION}" --output none
echo "${RESOURCEGROUP}" > "${SHARED_DIR}/resourcegroup_aks"

K8S_VERSION_ARGS=()
if [[ -n "${AKS_K8S_VERSION}" ]]; then
  K8S_VERSION_ARGS=(--kubernetes-version "${AKS_K8S_VERSION}")
else
  LATEST_VERSION="$(az aks get-versions \
    --location "${AZURE_LOCATION}" \
    --output tsv \
    --query 'orchestrators[?isPreview==`null`].orchestratorVersion' | sort -V | tail -n1)"
  K8S_VERSION_ARGS=(--kubernetes-version "${LATEST_VERSION}")
fi

echo "Creating AKS cluster ${CLUSTER} (${AKS_NODE_COUNT} x ${AKS_NODE_VM_SIZE})"
az aks create \
  --name "${CLUSTER}" \
  --resource-group "${RESOURCEGROUP}" \
  --location "${AZURE_LOCATION}" \
  --node-count "${AKS_NODE_COUNT}" \
  --node-vm-size "${AKS_NODE_VM_SIZE}" \
  --generate-ssh-keys \
  --network-plugin azure \
  "${K8S_VERSION_ARGS[@]}" \
  --output none

echo "Waiting for AKS cluster to be ready"
az aks wait --created \
  --name "${CLUSTER}" \
  --resource-group "${RESOURCEGROUP}" \
  --interval 30

echo "${CLUSTER}" > "${SHARED_DIR}/cluster-name"

echo "Getting kubeconfig: ${SHARED_DIR}/kubeconfig"
az aks get-credentials \
  --name "${CLUSTER}" \
  --resource-group "${RESOURCEGROUP}" \
  --file "${SHARED_DIR}/kubeconfig" \
  --overwrite-existing

chmod go-rwx "${SHARED_DIR}/kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
kubectl get nodes
kubectl version

echo "Installing cert-manager (required for CAPI webhooks)..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m
echo "cert-manager installed."
