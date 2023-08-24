#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
REGION="${LEASED_RESOURCE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
# yq-go is not available in the ci image...
#BASE_DOMAIN_RESOURCE_GROUP_NAME=$(yq-go r "${CONFIG}" 'platform.azure.baseDomainResourceGroupName')
BASE_DOMAIN_RESOURCE_GROUP_NAME=$(fgrep 'baseDomainResourceGroupName:' ${CONFIG} | cut -d ":" -f2 | tr -d " ")

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [ ! -f "$AZURE_AUTH_LOCATION" ]; then
    echo "File not found: $AZURE_AUTH_LOCATION"
    exit 1
fi

# jq is not available in the ci image...
# AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
AZURE_SUBSCRIPTION_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep subscriptionId | cut -d ":" -f2)
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "AZURE_SUBSCRIPTION_ID is empty"
    exit 1
fi

# AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
AZURE_TENANT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep tenantId | cut -d ":" -f2)
export AZURE_TENANT_ID
if [ -z "$AZURE_TENANT_ID" ]; then
    echo "AZURE_TENANT_ID is empty"
    exit 1
fi

# AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep clientId | cut -d ":" -f2)
export AZURE_CLIENT_ID
if [ -z "$AZURE_CLIENT_ID" ]; then
    echo "AZURE_CLIENT_ID is empty"
    exit 1
fi

# AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_SECRET=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\" ' | tr "," "\n" | grep clientSecret | cut -d ":" -f2)
export AZURE_CLIENT_SECRET
if [ -z "$AZURE_CLIENT_SECRET" ]; then
    echo "AZURE_CLIENT_SECRET is empty"
    exit 1
fi

# extract azure credentials requests from the release image
HOME="${HOME:-/tmp/home}"
export HOME
XDG_RUNTIME_DIR="${HOME}/run"
export XDG_RUNTIME_DIR
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

oc registry login
oc adm release extract --credentials-requests --cloud=azure --to="/tmp/credrequests" "${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

# Create manual credentials using client secret for openshift-cluster-api.
# This is a temp workaround until cluster-api supports workload identity
# authentication. This enables the openshift-e2e test to succeed when running
# the cluster-api tests. Placing it here so ccoctl can override it with
# generated credentials as work is done to support workload identity.
# At the time of this comment, openshift-cluster-api appears to only be
# enabled with the TechPreviewNoUpgrade FeatureSet.
mkdir -p "/tmp/manifests"
echo "Creating credentials for openshift-cluster-api..."
cat > "/tmp/manifests/openshift-cluster-api-capz-manager-bootstrap-credentials-credentials.yaml" << EOF
apiVersion: v1
stringData:
  azure_client_id: ${AZURE_CLIENT_ID}
  azure_client_secret: ${AZURE_CLIENT_SECRET}
  azure_region: ${REGION}
  azure_resourcegroup: ${CLUSTER_NAME}
  azure_subscription_id: ${AZURE_SUBSCRIPTION_ID}
  azure_tenant_id: ${AZURE_TENANT_ID}
kind: Secret
metadata:
  name: capz-manager-bootstrap-credentials
  namespace: openshift-cluster-api
EOF

# create metadata so cluster resource group is deleted in ipi-deprovision-deprovision
cat > ${SHARED_DIR}/metadata.json << EOF
{"infraID":"${CLUSTER_NAME}","azure":{"region":"${REGION}","resourceGroupName":"${CLUSTER_NAME}"}}
EOF

if [ "${ENABLE_TECH_PREVIEW_CREDENTIALS_REQUESTS:-\"false\"}" == "true" ]; then
  ADDITIONAL_CCOCTL_ARGS="--enable-tech-preview"
else
  ADDITIONAL_CCOCTL_ARGS=""
fi

# create required credentials infrastructure and installer manifests
ccoctl azure create-all \
  --name="${CLUSTER_NAME}" \
  --region="${REGION}" \
  --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
  --tenant-id="${AZURE_TENANT_ID}" \
  --credentials-requests-dir="/tmp/credrequests" \
  --dnszone-resource-group-name="${BASE_DOMAIN_RESOURCE_GROUP_NAME}" \
  --storage-account-name="$(tr -d '-' <<< ${CLUSTER_NAME})oidc" \
  --output-dir="/tmp" \
  ${ADDITIONAL_CCOCTL_ARGS}

# Output authentication file for ci logs
echo "Cluster authentication:"
cat "/tmp/manifests/cluster-authentication-02-config.yaml"
echo -e "\n"

# save the resource_group name for use by ipi-conf-azure-provisioned-resourcegroup
echo $CLUSTER_NAME > ${SHARED_DIR}/resourcegroup

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp "${FILE}" "${MPREFIX}_$FILE"; done
