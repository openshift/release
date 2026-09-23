#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Version comparison functions using sort -V
function version_ge() {
  # Returns 0 (true) if $1 >= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ "${GCP_CCO_MANUAL_USE_MINIMAL_PERMISSIONS}" != "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - INFO: GCP_CCO_MANUAL_USE_MINIMAL_PERMISSIONS is not 'yes', so using the default GCP credential for installation."
  exit 0
fi

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
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
  TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

dir=$(mktemp -d)
pushd "${dir}"

cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
KUBECONFIG="" oc registry login --to pull-secret
ocp_version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm pull-secret

echo "[DEBUG] current OCP version: '${ocp_version}'"

popd

# the OCP version supports compute.platform.gcp.serviceAccount
EXPECTED_OCP_VERSION="4.17"

if version_ge "${ocp_version}" "${EXPECTED_OCP_VERSION}"; then
  echo "$(date -u --rfc-3339=seconds) - INFO: Enabling the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC with CCO in Manual mode..."
  cp "${CLUSTER_PROFILE_DIR}/ipi-xpn-cco-manual-permissions.json" "${SHARED_DIR}/xpn_min_perm_cco_manual.json"
else
    echo "$(date -u --rfc-3339=seconds) - ERROR: GCP_CCO_MANUAL_USE_MINIMAL_PERMISSIONS is 'yes', but the OCP version doesn't support 'compute.platform.gcp.serviceAccount', so using the default GCP credential for installation."
fi
