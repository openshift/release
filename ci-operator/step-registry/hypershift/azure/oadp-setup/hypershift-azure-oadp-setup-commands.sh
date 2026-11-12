#!/bin/bash
set -euo pipefail

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OADP_NAMESPACE=openshift-adp
OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/konveyor/hypershift-oadp-plugin:latest}"

RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup")

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_CLIENT_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
AZURE_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
AZURE_TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
AZURE_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")

az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

# ARO exposes the resource group that holds node disks through the Infrastructure object.
DISK_RESOURCE_GROUP=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
if [[ -z "${DISK_RESOURCE_GROUP}" ]]; then
  echo "could not determine the management cluster disk resource group" >&2
  exit 1
fi

STORAGE_ACCOUNT="hsoadp$(printf '%s' "${PROW_JOB_ID}" | sha256sum | cut -c1-14)"
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

oc get namespace "${OADP_NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${OADP_NAMESPACE}"

# Pipeline plugin images require the CI pull secret.
if [[ -f /etc/ci-pull-credentials/.dockerconfigjson ]]; then
  oc create secret docker-registry ci-pull-secret \
    --namespace "${OADP_NAMESPACE}" \
    --from-file=.dockerconfigjson=/etc/ci-pull-credentials/.dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
  oc secrets link default ci-pull-secret --for=pull -n "${OADP_NAMESPACE}"
fi

# The Azure plugin reads all settings, including the storage account key, from one credentials
# file stored under the "cloud" key. Keep it out of the job log.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
CREDENTIALS_FILE=$(mktemp)
trap 'rm -f "${CREDENTIALS_FILE}"' EXIT
chmod 600 "${CREDENTIALS_FILE}"
printf 'AZURE_STORAGE_ACCOUNT_ACCESS_KEY=%s\nAZURE_SUBSCRIPTION_ID=%s\nAZURE_TENANT_ID=%s\nAZURE_CLIENT_ID=%s\nAZURE_CLIENT_SECRET=%s\nAZURE_RESOURCE_GROUP=%s\nAZURE_CLOUD_NAME=AzurePublicCloud\n' \
  "${STORAGE_KEY}" "${AZURE_SUBSCRIPTION_ID}" "${AZURE_TENANT_ID}" "${AZURE_CLIENT_ID}" "${AZURE_CLIENT_SECRET}" "${DISK_RESOURCE_GROUP}" > "${CREDENTIALS_FILE}"
oc create secret generic cloud-credentials-azure \
  --namespace "${OADP_NAMESPACE}" \
  --from-file=cloud="${CREDENTIALS_FILE}" \
  --dry-run=client -o yaml | oc apply -f -
$WAS_TRACING && set -x
unset STORAGE_KEY AZURE_CLIENT_SECRET

# CSI snapshots need exactly one VolumeSnapshotClass per driver labeled for Velero.
# The Azure Disk CSI driver operator creates csi-azuredisk-vsc on OpenShift.
if ! oc get volumesnapshotclass csi-azuredisk-vsc >/dev/null 2>&1; then
  echo "VolumeSnapshotClass csi-azuredisk-vsc not found; the Azure Disk CSI driver operator should have created it" >&2
  exit 1
fi
oc label volumesnapshotclass csi-azuredisk-vsc velero.io/csi-volumesnapshot-class=true --overwrite

oc apply -f - <<YAML
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-instance
  namespace: ${OADP_NAMESPACE}
spec:
  backupImages: false
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
    velero:
      customPlugins:
      - name: hypershift-oadp-plugin
        image: ${OADP_PLUGIN_IMAGE}
      defaultPlugins:
      - openshift
      - azure
      - csi
      disableFsBackup: false
      resourceTimeout: 2h
      noDefaultBackupLocation: true
      logLevel: debug
YAML

oc wait --for=condition=Available deployment/velero -n "${OADP_NAMESPACE}" --timeout=300s

oc apply -f - <<YAML
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${OADP_NAMESPACE}
spec:
  provider: azure
  objectStorage:
    bucket: ${BLOB_CONTAINER}
    prefix: backup-objects
  credential:
    name: cloud-credentials-azure
    key: cloud
  config:
    resourceGroup: ${RESOURCE_GROUP}
    storageAccount: ${STORAGE_ACCOUNT}
    storageAccountKeyEnvVar: AZURE_STORAGE_ACCOUNT_ACCESS_KEY
    subscriptionId: ${AZURE_SUBSCRIPTION_ID}
YAML

echo "Azure OADP setup complete"
