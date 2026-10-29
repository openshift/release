#!/bin/bash
set -euo pipefail

if [[ ! -f "${KUBECONFIG}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

VELERO_VERSION=v1.13.2
VELERO_IMAGE="velero/velero:${VELERO_VERSION}"
AZURE_PLUGIN_IMAGE=velero/velero-plugin-for-microsoft-azure:v1.9.0
VELERO_NAMESPACE=openshift-adp

if [[ -f "${SHARED_DIR}/resourcegroup_aks" ]]; then
  RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup_aks")
else
  RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup")
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION=/etc/hypershift-ci-jobs-azurecreds/credentials.json
fi
AZURE_CLIENT_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
AZURE_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
AZURE_TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
AZURE_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")

az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

# The disk snapshotter needs the management cluster's disk resource group.
# AKS puts node disks in its generated resource group; ARO exposes its disk
# resource group through the OpenShift Infrastructure object.
if [[ -f "${SHARED_DIR}/resourcegroup_aks" ]]; then
  DISK_RESOURCE_GROUP=$(az aks list --resource-group "${RESOURCE_GROUP}" --query '[0].nodeResourceGroup' --output tsv)
else
  DISK_RESOURCE_GROUP=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
fi
if [[ -z "${DISK_RESOURCE_GROUP}" || "${DISK_RESOURCE_GROUP}" == "None" ]]; then
  echo "could not determine the management cluster disk resource group" >&2
  exit 1
fi

STORAGE_ACCOUNT="hsvelero$(printf '%s' "${PROW_JOB_ID}" | sha256sum | cut -c1-13)"
BLOB_CONTAINER=backups
az storage account create \
  --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" \
  --location "${HYPERSHIFT_AZURE_LOCATION}" --kind StorageV2 --sku Standard_LRS \
  --allow-blob-public-access false --output none
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" \
  --query '[0].value' --output tsv)
az storage container create \
  --name "${BLOB_CONTAINER}" --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" --output none

CREDENTIALS_FILE=$(mktemp)
trap 'rm -f "${CREDENTIALS_FILE}"' EXIT
chmod 600 "${CREDENTIALS_FILE}"
printf 'AZURE_STORAGE_ACCOUNT_ACCESS_KEY=%s\nAZURE_SUBSCRIPTION_ID=%s\nAZURE_TENANT_ID=%s\nAZURE_CLIENT_ID=%s\nAZURE_CLIENT_SECRET=%s\nAZURE_RESOURCE_GROUP=%s\nAZURE_CLOUD_NAME=AzurePublicCloud\n' \
  "${STORAGE_KEY}" "${AZURE_SUBSCRIPTION_ID}" "${AZURE_TENANT_ID}" "${AZURE_CLIENT_ID}" "${AZURE_CLIENT_SECRET}" "${DISK_RESOURCE_GROUP}" > "${CREDENTIALS_FILE}"
unset STORAGE_KEY AZURE_CLIENT_SECRET

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac
VELERO_ARCHIVE=$(mktemp)
trap 'rm -f "${CREDENTIALS_FILE}" "${VELERO_ARCHIVE}"' EXIT
curl --fail --location --retry 3 --silent --show-error \
  --output "${VELERO_ARCHIVE}" \
  "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf "${VELERO_ARCHIVE}" -C /tmp "velero-${VELERO_VERSION}-linux-${ARCH}/velero"
VELERO_CLI="/tmp/velero-${VELERO_VERSION}-linux-${ARCH}/velero"

oc create namespace "${VELERO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
"${VELERO_CLI}" install \
  --namespace "${VELERO_NAMESPACE}" \
  --image "${VELERO_IMAGE}" \
  --provider azure \
  --plugins "${AZURE_PLUGIN_IMAGE}" \
  --bucket "${BLOB_CONTAINER}" \
  --secret-file "${CREDENTIALS_FILE}" \
  --backup-location-config "resourceGroup=${RESOURCE_GROUP},storageAccount=${STORAGE_ACCOUNT},storageAccountKeyEnvVar=AZURE_STORAGE_ACCOUNT_ACCESS_KEY,subscriptionId=${AZURE_SUBSCRIPTION_ID}" \
  --snapshot-location-config "apiTimeout=5m,resourceGroup=${DISK_RESOURCE_GROUP},subscriptionId=${AZURE_SUBSCRIPTION_ID}" \
  --use-volume-snapshots=true

# Pipeline plugin images require the CI pull secret. Velero's service account is
# created by the install command, so link the secret before waiting for rollout.
oc create secret generic ci-pull-secret \
  --namespace "${VELERO_NAMESPACE}" \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/etc/ci-pull-credentials/.dockerconfigjson \
  --dry-run=client -o yaml | oc apply -f -
oc patch serviceaccount/velero -n "${VELERO_NAMESPACE}" --type=merge \
  -p '{"imagePullSecrets":[{"name":"ci-pull-secret"}]}'
# Velero 1.13 derives an init-container name from the full image repository.
# Pipeline image names can exceed Kubernetes' name limit, so use a fixed name.
PLUGIN_PATCH=$(jq -nc --arg image "${OADP_HYPERSHIFT_PLUGIN_IMAGE}" '[{"op":"add","path":"/spec/template/spec/initContainers/-","value":{"name":"hypershift-oadp-plugin","image":$image,"imagePullPolicy":"Always","volumeMounts":[{"name":"plugins","mountPath":"/target"}]}}]')
oc patch deployment/velero -n "${VELERO_NAMESPACE}" --type=json -p "${PLUGIN_PATCH}"
oc rollout status deployment/velero -n "${VELERO_NAMESPACE}" --timeout=10m
oc get backupstoragelocation/default -n "${VELERO_NAMESPACE}" -o yaml
