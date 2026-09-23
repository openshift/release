#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${UNIQUE_HASH}

if [[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "true" ]]; then
  echo "> Using minimal permissions for 'ccoctl'..."
  export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/ccoctl_sa.json
else
  export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
fi
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST,
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with tag name, to avoid auth error
# when accessing it, always use build farm registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

# The CredentialsRequests are required for cleaning up resources in GCP and since
# the step registry does not support passing sub-directories within the ${SHARED_DIR},
# we re-extract the CredentialsRequests from the release image to /tmp/credrequests
# for deprovision.
# https://docs.ci.openshift.org/docs/architecture/step-registry/#sharing-data-between-steps
echo "> Extract gcp credentials requests from the release image"
dir="$(mktemp -d)"
pushd "${dir}" >/dev/null
cleanup() {
  rm -f pull-secret
  popd >/dev/null || true
  rm -rf "${dir}"
}
trap cleanup EXIT

cp "${CLUSTER_PROFILE_DIR}/pull-secret" pull-secret
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
KUBECONFIG="" oc registry login --to pull-secret
oc adm release extract --registry-config pull-secret --credentials-requests --cloud=gcp --to="/tmp/credrequests" "${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

echo "> Output gcp credentials requests to directory: /tmp/credrequests"
ls "/tmp/credrequests"

echo "> Delete credentials infrastructure created by oidc-creds-provision-provision configure step"
ccoctl gcp delete --name="${infra_name}" --project="${PROJECT}" --credentials-requests-dir="/tmp/credrequests"
