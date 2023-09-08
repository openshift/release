#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# check if OCP version will be equal to or greater than the minimum version
# $1 - the minimum version to be compared with
# return 0 if OCP version >= the minimum version, otherwise 1
function version_check() {
  local -r minimum_version="$1"

  dir=$(mktemp -d)
  pushd "${dir}"

  cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
  oc registry login --to pull-secret
  ocp_version=$(oc adm release info --registry-config pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)

  if [[ "${ocp_version}" == "${minimum_version}" ]] || [[ "${ocp_version}" > "${minimum_version}" ]]; then
    ret=0
  else
    ret=1
  fi

  rm pull-secret
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