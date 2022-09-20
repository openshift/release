#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=Standard_D32s_v3
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=Standard_D16s_v3
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=Standard_D8s_v3
fi

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  azure:
    region: ${REGION}
controlPlane:
  name: master
  platform:
    azure:
      type: ${master_type}
compute:
- name: worker
  replicas: ${workers}
  platform:
    azure:
      type: ${COMPUTE_NODE_TYPE}
EOF

if [ -z "${OUTBOUND_TYPE}" ]; then
  echo "Outbound Type is not defined"
else
  if [ X"${OUTBOUND_TYPE}" == X"UserDefinedRouting" ]; then
    echo "Writing 'outboundType: UserDefinedRouting' to install-config"
    PATCH="${SHARED_DIR}/install-config-outboundType.yaml.patch"
    cat > "${PATCH}" << EOF
platform:
  azure:
    outboundType: ${OUTBOUND_TYPE}
EOF
    yq-go m -x -i "${CONFIG}" "${PATCH}"
  else
    echo "${OUTBOUND_TYPE} is not supported yet" || exit 1
  fi
fi

version=$(getVersion)
echo "get ocp version: ${version}"
REQUIRED_OCP_VERSION="4.12"
isOldVersion=true
if [ -n "${version}" ] && [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
  isOldVersion=false
fi

PUBLISH=$(yq-go r "${CONFIG}" "publish")
echo "publish: ${PUBLISH}"
echo "is Old Version: ${isOldVersion}"
if [ ${isOldVersion} = true ] || [ -z "${PUBLISH}" ] || [ X"${PUBLISH}" == X"External" ]; then
  echo "Write the 'baseDomainResourceGroupName: os4-common' to install-config"
  PATCH="${SHARED_DIR}/install-config-baseDomainRG.yaml.patch"
    cat > "${PATCH}" << EOF
platform:
  azure:
    baseDomainResourceGroupName: os4-common
EOF
    yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  echo "Omit baseDomainResourceGroupName for private cluster"
fi
