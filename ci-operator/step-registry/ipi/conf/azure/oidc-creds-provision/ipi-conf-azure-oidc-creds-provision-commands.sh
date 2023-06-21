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
# jq is not available in the ci image...
# AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
AZURE_SUBSCRIPTION_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep subscriptionId | cut -d ":" -f2)
# AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
AZURE_TENANT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep tenantId | cut -d ":" -f2)
export AZURE_TENANT_ID
# AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_ID=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep clientId | cut -d ":" -f2)
export AZURE_CLIENT_ID
# AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
AZURE_CLIENT_SECRET=$(cat ${AZURE_AUTH_LOCATION} | tr -d '{}\"' | tr "," "\n" | grep clientSecret | cut -d ":" -f2)
export AZURE_CLIENT_SECRET

# extract azure credentials requests from the release image
oc registry login
oc adm release extract --credentials-requests --cloud=azure --to="/tmp/credrequests" "${RELEASE_IMAGE_LATEST}"

# create required credentials infrastructure and installer manifests
ccoctl azure create-all \
  --name="${CLUSTER_NAME}" \
  --region="${REGION}" \
  --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
  --credentials-requests-dir="/tmp/credrequests" \
  --dnszone-resource-group-name="${BASE_DOMAIN_RESOURCE_GROUP_NAME}" \
  --storage-account-name="$(tr -d '-' <<< ${CLUSTER_NAME})oidc" \
  --output-dir="/tmp"

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
