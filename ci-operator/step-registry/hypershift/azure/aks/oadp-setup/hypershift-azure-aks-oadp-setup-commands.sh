#!/bin/bash

# WARNING:This script must be run after installing the hosted cluster.
# The SCC crds from this script are required for Velero and Node Agent
# to run but then, HostedCluster on AKS fails to start. Some pods from
# HCP namespace fail with "container has runAsNonRoot and image will run as root"

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
PULL_SECRET_FILE="/etc/ci-pull-credentials/.dockerconfigjson"
REDHAT_OPERATORS_INDEX_TAG="${REDHAT_OPERATORS_INDEX_TAG:-v4.21}"

export OADP_OPERATOR_SUB_INSTALL_NAMESPACE="${OADP_OPERATOR_SUB_INSTALL_NAMESPACE:-openshift-adp}"
export OADP_OPERATOR_SUB_PACKAGE="${OADP_OPERATOR_SUB_PACKAGE:-redhat-oadp-operator}"
export OADP_OPERATOR_SUB_CHANNEL="${OADP_OPERATOR_SUB_CHANNEL:-stable}"
export OADP_OPERATOR_SUB_SOURCE="${OADP_OPERATOR_SUB_SOURCE:-redhat-operators}"
export OADP_SUB_TARGET_NAMESPACES="${OADP_SUB_TARGET_NAMESPACES:-openshift-adp}"
export OLM_NAMESPACE="${OLM_NAMESPACE:-olm}"
export OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/redhat-user-workloads/ocp-art-tenant/oadp-hypershift-oadp-plugin-main:main}"

# Create OLM namespace and pull secret for CatalogSource
echo "Creating OLM namespace..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OLM_NAMESPACE}
EOF

echo "Creating pull secret in OLM namespace..."
oc delete secret pull-secret -n "${OLM_NAMESPACE}" 2>/dev/null || true
oc create secret generic pull-secret \
  --from-file=.dockerconfigjson="${PULL_SECRET_FILE}" \
  --type=kubernetes.io/dockerconfigjson \
  --namespace="${OLM_NAMESPACE}"

echo "Deploying Red Hat Operators CatalogSource..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: ${OLM_NAMESPACE}
spec:
  displayName: Red Hat Operators
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
    nodeSelector:
      kubernetes.io/os: linux
      node-role.kubernetes.io/master: ""
    priorityClassName: system-cluster-critical
    securityContextConfig: restricted
    tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoExecute
      key: node.kubernetes.io/unreachable
      operator: Exists
      tolerationSeconds: 120
    - effect: NoExecute
      key: node.kubernetes.io/not-ready
      operator: Exists
      tolerationSeconds: 120
  icon:
    base64data: ""
    mediatype: ""
  image: registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATORS_INDEX_TAG}
  secrets:
  - pull-secret
  priority: -100
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

# Create the openshift-adp namespace (must exist before creating pull secret)
echo "Creating openshift-adp namespace..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# Create pull secret in openshift-adp namespace BEFORE subscribing to operator
echo "Creating pull secret in openshift-adp namespace..."
oc delete secret pull-secret -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" 2>/dev/null || true
oc create secret generic pull-secret \
  --from-file=.dockerconfigjson="${PULL_SECRET_FILE}" \
  --type=kubernetes.io/dockerconfigjson \
  --namespace="${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"

# Create OperatorGroup
if [[ "${OADP_SUB_TARGET_NAMESPACES}" == "!install" ]]; then
  OADP_SUB_TARGET_NAMESPACES="${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
fi
echo "Installing ${OADP_OPERATOR_SUB_PACKAGE} from channel: ${OADP_OPERATOR_SUB_CHANNEL} in source: ${OADP_OPERATOR_SUB_SOURCE} into ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"

echo "Creating OperatorGroup..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo "\"${OADP_SUB_TARGET_NAMESPACES}\"" | sed "s|,|\"\n  - \"|g")
EOF

# Create Subscription
echo "Creating Subscription..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${OADP_OPERATOR_SUB_PACKAGE}"
  namespace: "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${OADP_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${OADP_OPERATOR_SUB_PACKAGE}"
  source: "${OADP_OPERATOR_SUB_SOURCE}"
  sourceNamespace: "${OLM_NAMESPACE}"
EOF

# Wait for controller manager service account and patch with pull secret
echo "Waiting for openshift-adp-controller-manager service account..."
until oc get serviceaccount openshift-adp-controller-manager -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" &>/dev/null; do
    echo "Waiting for serviceaccount openshift-adp-controller-manager to exist..."
    sleep 5
done

oc patch serviceaccount -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" openshift-adp-controller-manager -p '{"imagePullSecrets": [{"name": "pull-secret"}]}'

# Delete all pods so they restart with the pull secret
oc delete pod -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" --all

# Apply required CRDs and Infrastructure resource
echo "Applying required CRDs..."
oc apply -f https://raw.githubusercontent.com/openshift/api/refs/heads/master/security/v1/zz_generated.crd-manifests/0000_03_config-operator_01_securitycontextconstraints.crd.yaml
oc apply -f https://raw.githubusercontent.com/openshift/api/refs/heads/master/route/v1/zz_generated.crd-manifests/routes.crd.yaml
oc apply -f https://raw.githubusercontent.com/openshift/api/refs/heads/master/config/v1/zz_generated.crd-manifests/0000_10_config-operator_01_infrastructures-Default.crd.yaml

timeout 60s bash -c 'until oc get crd infrastructures.config.openshift.io; do sleep 5; done'
oc wait --for condition=established --timeout=60s crd infrastructures.config.openshift.io

echo "Creating Infrastructure resource..."
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: Infrastructure
metadata:
  labels:
    hypershift.openshift.io/managed: "true"
  name: cluster
spec:
  cloudConfig:
    name: ""
  platformSpec:
    azure: {}
    type: Azure
EOF

# Wait for CSV to reach Succeeded (AFTER pod restart so pods have pull secret)
echo "Waiting for CSV to reach Succeeded..."
RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" "${OADP_OPERATOR_SUB_PACKAGE}" -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" "${CSV}" -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "${OADP_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${OADP_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${OADP_OPERATOR_SUB_PACKAGE}"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}"
  exit 1
fi

echo "successfully installed ${OADP_OPERATOR_SUB_PACKAGE}"

RESOURCEGROUP_AKS="$(cat "${SHARED_DIR}/resourcegroup_aks")"

# Disable tracing due to credential handling
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

echo "Logging into Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
BUCKET_NAME="${OADP_AZURE_BUCKET_NAME:-hypershift-oadp-${CLUSTER_NAME}}"
# Create storage account with a unique name (max 24 chars, lowercase alphanumeric)
STORAGE_ACCOUNT_NAME="oadp${CLUSTER_NAME:0:20}"
STORAGE_ACCOUNT_NAME="$(echo "${STORAGE_ACCOUNT_NAME}" | tr -cd '[:lower:][:digit:]' | cut -c1-24)"

echo "Creating storage account ${STORAGE_ACCOUNT_NAME} in resource group ${RESOURCEGROUP_AKS}..."
az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RESOURCEGROUP_AKS}" \
  --location "${HYPERSHIFT_AZURE_LOCATION:-eastus2}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

echo "${STORAGE_ACCOUNT_NAME}" > "${SHARED_DIR}/oadp-storage-account-name"

echo "Creating blob container ${BUCKET_NAME}..."
az storage container create \
  --name "${BUCKET_NAME}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --output none

echo "Getting storage account key..."
STORAGE_ACCOUNT_KEY="$(az storage account keys list --account-name "${STORAGE_ACCOUNT_NAME}" --resource-group "${RESOURCEGROUP_AKS}" --query '[0].value' -o tsv)"

echo "Creating Azure credentials secret..."
AZURE_CREDS_FILE="$(mktemp)"
cat <<EOF > "${AZURE_CREDS_FILE}"
AZURE_SUBSCRIPTION_ID=${AZURE_AUTH_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_AUTH_TENANT_ID}
AZURE_CLIENT_ID=${AZURE_AUTH_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_AUTH_CLIENT_SECRET}
AZURE_RESOURCE_GROUP=${RESOURCEGROUP_AKS}
AZURE_STORAGE_ACCOUNT_ACCESS_KEY=${STORAGE_ACCOUNT_KEY}
EOF

oc delete secret "${CLUSTER_NAME}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" 2>/dev/null || true
oc create secret generic "${CLUSTER_NAME}" -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" --from-file cloud="${AZURE_CREDS_FILE}"
rm -f "${AZURE_CREDS_FILE}"

# Create DataProtectionApplication (without backup/snapshot locations)
echo "Creating DataProtectionApplication..."
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-azure
  namespace: ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}
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
        - kubevirt
        - csi
      disableFsBackup: false
      resourceTimeout: 2h
      noDefaultBackupLocation: true
      logLevel: debug
EOF

echo "Waiting for velero service account..."
until oc get serviceaccount velero -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" &>/dev/null; do
    echo "Waiting for serviceaccount velero to exist..."
    sleep 5
done

oc patch serviceaccount -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" velero -p '{"imagePullSecrets": [{"name": "pull-secret"}]}'

if oc get pod -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -l deploy=velero &>/dev/null; then
  oc delete pod -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -l deploy=velero
fi
if oc get pod -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -l name=node-agent &>/dev/null; then
  oc delete pod -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" -l name=node-agent
fi

echo "Waiting for velero Deployment to be ready..."
oc rollout status deployment/velero -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" --timeout=300s

echo "Waiting for node-agent DaemonSet to be ready..."
oc rollout status daemonset/node-agent -n "${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}" --timeout=300s

# Create BackupStorageLocation
echo "Creating BackupStorageLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}
spec:
  provider: azure
  objectStorage:
    bucket: ${BUCKET_NAME}
    prefix: backup-objects
  credential:
    name: ${CLUSTER_NAME}
    key: cloud
  config:
    resourceGroup: ${RESOURCEGROUP_AKS}
    storageAccount: ${STORAGE_ACCOUNT_NAME}
    subscriptionId: ${AZURE_AUTH_SUBSCRIPTION_ID}
    storageAccountKeyEnvVar: AZURE_STORAGE_ACCOUNT_ACCESS_KEY
EOF

# Create VolumeSnapshotLocation
echo "Creating VolumeSnapshotLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: VolumeSnapshotLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${OADP_OPERATOR_SUB_INSTALL_NAMESPACE}
spec:
  provider: azure
  credential:
    name: ${CLUSTER_NAME}
    key: cloud
  config:
    resourceGroup: ${RESOURCEGROUP_AKS}
    subscriptionId: ${AZURE_AUTH_SUBSCRIPTION_ID}
    incremental: "true"
EOF

# Setup VolumeSnapshotClass for Azure Disk CSI Driver.
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: azure-disk-csi-snapclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: disk.csi.azure.com
deletionPolicy: Retain
EOF

echo "OADP setup complete"

# Prevent "rpc error: code = Unknown desc = configmaps "config" not found" during backup.
# See: https://redhat.atlassian.net/browse/CNTRLPLANE-2033
cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-apiserver
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: openshift-apiserver
data:
  config.yaml: |
    {
      "imagePolicyConfig": {
        "imageStreamImportMode": "Legacy",
        "internalRegistryHostname": "image-registry.openshift-image-registry.svc:5000"
      }
    }
EOF
