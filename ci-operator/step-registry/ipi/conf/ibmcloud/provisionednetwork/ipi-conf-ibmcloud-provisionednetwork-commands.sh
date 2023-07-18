#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

CONFIG="${SHARED_DIR}/install-config.yaml"
function getVersion() {
  local release_image=""
  if [ -n "${RELEASE_IMAGE_INITIAL-}" ]; then
    release_image=${RELEASE_IMAGE_INITIAL}
  elif [ -n "${RELEASE_IMAGE_LATEST-}" ]; then
    release_image=${RELEASE_IMAGE_LATEST}     
  fi

  local version=""
  if [ ${release_image} != "" ]; then
    oc registry login
    version=$(oc adm release info ${release_image} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)    
  fi
  echo "${version}"
}

version=$(getVersion)
echo "get ocp version: ${version}"
REQUIRED_OCP_VERSION="4.13"
isOldVersion=true
if [ -n "${version}" ] && [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
  isOldVersion=false
fi

if [ ${isOldVersion} = true ]; then
    yq-go d -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.networkResourceGroupName'
fi
#specify resourceGroupName in new version

cat "${SHARED_DIR}/customer_vpc_subnets.yaml"

yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/customer_vpc_subnets.yaml"


