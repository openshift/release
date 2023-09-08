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
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

CLUSTER_NAME=${NAMESPACE}-${UNIQUE_HASH}
RESOURCE_GROUP=${CLUSTER_NAME}
AZURE_AUTH_LOCATION="${SHARED_DIR}/osServicePrincipal.json"
APP_ID=$(jq -r .clientId "${AZURE_AUTH_LOCATION}")
TENANT_ID=$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")
AAD_CLIENT_SECRET=$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")
SUBSCRIPTION_ID=$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")
AZURE_REGION=$(yq-go r "${SHARED_DIR}/install-config.yaml" "platform.azure.region")

PATCH="/tmp/install-config-rg.yaml.patch"
# create a patch with resource group configuration
cat > "${PATCH}" << EOF
platform:
  azure:
    resourceGroupName: ${RESOURCE_GROUP}
EOF
# apply patch to install-config
yq-go m -x -i "${SHARED_DIR}/install-config.yaml" "${PATCH}"

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
source ${SHARED_DIR}/azurestack-login-script.sh

az group create --name "$RESOURCE_GROUP" --location "$AZURE_REGION"
echo "${RESOURCE_GROUP}" > "${SHARED_DIR}/RESOURCE_GROUP_NAME"

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

oc registry login
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help
oc adm release extract --credentials-requests --cloud=azure --to=/tmp/credentials-request ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"

echo "CR manifest files:"
ls /tmp/credentials-request
files=$(ls -p /tmp/credentials-request/*.yaml | awk -F'/' '{print $NF}')
for f in $files
do
  SECRET_NAME=$(yq-go r "/tmp/credentials-request/${f}" "spec.secretRef.name")
  SECRET_NAMESPACE=$(yq-go r "/tmp/credentials-request/${f}" "spec.secretRef.namespace")
  FEATURE_GATE=$(yq-go r "/tmp/credentials-request/${f}" "metadata.annotations.[release.openshift.io/feature-gate]")
  FEATURE_SET=$(yq-go r "/tmp/credentials-request/${f}" "metadata.annotations.[release.openshift.io/feature-set]")

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
