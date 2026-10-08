#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/nutanix_context.sh"

CR_DIR="/tmp/credentials_request"
mkdir -p "${CR_DIR}"

MANIFEST_PREFIX="${SHARED_DIR}/manifest"

# Create the Nutanix credentials secret
cat > ${SHARED_DIR}/credentials <<EOF
credentials:
- type: basic_auth
  data:
    prismCentral:
      username: ${NUTANIX_USERNAME}
      password: ${NUTANIX_PASSWORD}
    prismElements: null
EOF

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

# Extract credential requests
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
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=nutanix --to "${CR_DIR}" ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"
rm pull-secret
popd

echo "Extracted credentials requests:"
ls -l "${CR_DIR}"

ADDITIONAL_CCOCTL_ARGS=""
if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
fi

# Create the credentials request manifest
ccoctl nutanix create-shared-secrets \
      --credentials-requests-dir="${CR_DIR}" \
      --output-dir="/tmp" \
      --credentials-source-filepath="${SHARED_DIR}/credentials" \
      ${ADDITIONAL_CCOCTL_ARGS}

echo "Created credentials request manifest:"
ls -l "/tmp/manifests"

# Copy the manifest to the shared directory
pushd "/tmp/manifests"
for FILE in *.yaml; do
  echo "Copying ${FILE} to ${MANIFEST_PREFIX}"
  cp "${FILE}" "${MANIFEST_PREFIX}_${FILE}"
done
popd
