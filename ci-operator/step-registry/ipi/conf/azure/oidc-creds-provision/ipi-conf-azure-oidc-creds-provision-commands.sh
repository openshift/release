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

# extract azure credentials requests from the release image
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=azure --to="/tmp/credrequests" ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"
rm pull-secret
popd

echo "CR manifest files:"
ls "/tmp/credrequests"

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

ADDITIONAL_CCOCTL_ARGS=""
# ENABLE_TECH_PREVIEW_CREDENTIALS_REQUESTS enables the relevant job for each operator to decide
# independantly if it needs the --enable-tech-preview added to the ccoctl command. It is very
# different from the TechPreviewNoUpgrade FEATURE_SET, which toggles cluster wide.
if [ "${ENABLE_TECH_PREVIEW_CREDENTIALS_REQUESTS:-\"false\"}" == "true" ]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
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
