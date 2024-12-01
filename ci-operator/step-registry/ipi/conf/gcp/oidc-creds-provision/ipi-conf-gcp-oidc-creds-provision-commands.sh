#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${UNIQUE_HASH}

if [[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "true" ]]; then
  echo "> Using minimal permissions for 'ccoctl'..."
  export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/ccoctl_sa.json
else
  export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
fi
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

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

echo "> Extract gcp credentials requests from the release image"
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
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=gcp --to="/tmp/credrequests" ${ADDITIONAL_OC_EXTRACT_ARGS} "${TESTING_RELEASE_IMAGE}"
rm pull-secret
popd

echo "> Output gcp credentials requests to directory: /tmp/credrequests"
ls "/tmp/credrequests"

ADDITIONAL_CCOCTL_ARGS=""
if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
fi

ccoctl_ouptut="/tmp/ccoctl_output"
echo "> Create required credentials infrastructure and installer manifests for workload identity"
ccoctl gcp create-all --name="${infra_name}" --project="${PROJECT}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp" ${ADDITIONAL_CCOCTL_ARGS} 2>&1 | tee "${ccoctl_ouptut}"

# oidc_pool and oidc_provider is using the same name as infra_name, so not have to enable the follwoing lines yet
# save oidc_provider info for upgrade
#oidc_pool=$(grep "Workload identity pool created" "${ccoctl_ouptut}" | awk -F"name " '{print $NF}')
#oidc_provider=$(grep "workload identity provider created" "${ccoctl_ouptut}" | awk -F"name " '{print $NF}')
#if [[ -n "${oidc_oidc_pool}" ]] && [[ -n "${oidc_provider}" ]]; then
#  echo "Saving oidc_pool: ${oidc_pool}"
#  echo "Saving oidc_provider: ${oidc_provider}"
#  echo "${oidc_pool}" > "${SHARED_DIR}/gcp_oidc_provider"
#  echo "${oidc_provider}" >> "${SHARED_DIR}/gcp_oidc_provider"
#fi

echo "> Copy generated service account signing from ccoctl target directory into shared directory"
cp -v "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "> Copy generated secret manifests from ccoctl target directory into shared directory"
cd "/tmp/manifests"
for FILE in *; do cp -v $FILE "${MPREFIX}_$FILE"; done
