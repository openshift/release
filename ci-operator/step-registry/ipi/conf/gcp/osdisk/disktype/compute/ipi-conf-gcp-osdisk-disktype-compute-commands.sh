#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

# check if OCP version will be equal to or greater than the minimum version
# $1 - the minimum version to be compared with
# return 0 if OCP version >= the minimum version, otherwise 1
function version_check() {
  local -r minimum_version="$1"
  local ret

  dir=$(mktemp -d)
  pushd "${dir}"

  cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
  KUBECONFIG="" oc registry login --to pull-secret
  ocp_version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
  rm pull-secret

  echo "[DEBUG] minimum OCP version: '${minimum_version}'"
  echo "[DEBUG] current OCP version: '${ocp_version}'"
  curr_x=$(echo "${ocp_version}" | cut -d. -f1)
  curr_y=$(echo "${ocp_version}" | cut -d. -f2)
  min_x=$(echo "${minimum_version}" | cut -d. -f1)
  min_y=$(echo "${minimum_version}" | cut -d. -f2)

  if [ ${curr_x} -gt ${min_x} ] || ( [ ${curr_x} -eq ${min_x} ] && [ ${curr_y} -ge ${min_y} ] ); then
    echo "[DEBUG] version_check result: ${ocp_version} >= ${minimum_version}"
    ret=0
  else
    echo "[DEBUG] version_check result: ${ocp_version} < ${minimum_version}"
    ret=1
  fi

  popd
  return ${ret}
}

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

# the OCP version supports disk type "pd-balanced"
EXPECTED_OCP_VERSION="4.14"

if [ -n "${COMPUTE_DISK_TYPE}" ]; then
  disk_type="${COMPUTE_DISK_TYPE}"
else
  if version_check "${EXPECTED_OCP_VERSION}"; then
    valid_types=("pd-balanced" "pd-ssd" "pd-standard")
  else
    valid_types=("pd-ssd" "pd-standard")
  fi
  echo -n "INFO: Valid disk types are "
  echo "${valid_types[@]}"

  count=${#valid_types[@]}
  selected_index=$(( RANDOM % ${count} ))
  disk_type=${valid_types[${selected_index}]}
  echo "INFO: Selected osDisk.diskType '${disk_type}' for cluster compute nodes."
fi

# if the selected diskType is the default pd-ssd, leave as it is
# otherwise, update the install-config
if [[ "${disk_type}" != "pd-ssd" ]]; then
  cat > "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      osDisk: 
        diskType: ${disk_type}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute.platform.gcp.osDisk.diskType in '${CONFIG}'."
  yq-go r "${CONFIG}" compute
fi

# save the selected osDisk.diskType for possible post-installation check
echo "${disk_type}" > ${SHARED_DIR}/compute-osdisk-disktype
