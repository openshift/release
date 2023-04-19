#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

# Set PATH to include YQ, installed via pip in the image
export PATH="$PATH:/usr/local/bin"

CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}
RESOURCE_GROUP=${CLUSTER_NAME}
AZURE_AUTH_LOCATION="${SHARED_DIR}/osServicePrincipal.json"
APP_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
AAD_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")
AZURE_REGION=$(yq -r .platform.azure.region "${SHARED_DIR}/install-config.yaml")

# shellcheck disable=SC2016
yq --arg name "${RESOURCE_GROUP}" -i -y '.platform.azure.resourceGroupName=$name' "${SHARED_DIR}/install-config.yaml"

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
source ${SHARED_DIR}/azurestack-login-script.sh

az group create --name "$RESOURCE_GROUP" --location "$AZURE_REGION"

oc registry login
oc adm release extract --credentials-requests --cloud=azure --to=/tmp/credentials-request "$RELEASE_IMAGE_LATEST"

ls /tmp/credentials-request
files=$(ls /tmp/credentials-request)
for f in $files
do
  SECRET_NAME=$(yq -r .spec.secretRef.name "/tmp/credentials-request/${f}")
  SECRET_NAMESPACE=$(yq -r .spec.secretRef.namespace "/tmp/credentials-request/${f}")
  FEATURE_GATE=$(yq -r '.metadata.annotations."release.openshift.io/feature-gate"' "/tmp/credentials-request/${f}")
  FEATURE_SET=$(yq -r '.metadata.annotations."release.openshift.io/feature-set"' "/tmp/credentials-request/${f}")

# 4.10 includes techpreview of CAPI which without the namespace: openshift-cluster-api
# fails to bootstrap. Below checks if TechPreviewNoUpgrade is annotated and if so skips
# creating that secret. In 4.12 the annotation was changed from feature-gate -> feature-set.
# So check for both.

  if [[ $FEATURE_GATE == *"TechPreviewNoUpgrade"* ]]; then
      continue
  fi

  if [[ $FEATURE_SET == *"TechPreviewNoUpgrade"* ]]; then
      continue
  fi

  # secret file name must be unique
  # to avoid only one secret take effect if putting multiple secrets under same namespace into one file
  filename=manifest_${SECRET_NAMESPACE}_${SECRET_NAME}_secret.yml
  cat >> "${SHARED_DIR}/${filename}" << EOF
apiVersion: v1
kind: Secret
metadata:
    name: ${SECRET_NAME}
    namespace: ${SECRET_NAMESPACE}
stringData:
  azure_subscription_id: ${SUBSCRIPTION_ID}
  azure_client_id: ${APP_ID}
  azure_client_secret: ${AAD_CLIENT_SECRET}
  azure_tenant_id: ${TENANT_ID}
  azure_resource_prefix: ${CLUSTER_NAME}
  azure_resourcegroup: ${RESOURCE_GROUP}
  azure_region: ${AZURE_REGION}
EOF

done
echo "${RESOURCE_GROUP}" > "${SHARED_DIR}/RESOURCE_GROUP_NAME"
