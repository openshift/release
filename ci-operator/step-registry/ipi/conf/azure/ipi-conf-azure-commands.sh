#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
oc registry login

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
master_type_prefix=""
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type_prefix=Standard_D32
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type_prefix=Standard_D16
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type_prefix=Standard_D8
fi
if [ -n "${master_type_prefix}" ]; then
  if [ "${OCP_ARCH}" = "amd64" ]; then
    master_type=${master_type_prefix}s_v3
  elif [ "${OCP_ARCH}" = "arm64" ]; then
    master_type=${master_type_prefix}ps_v5
  fi
fi

echo "Using control plane instance type: ${master_type}"
echo "Using compute instance type: ${COMPUTE_NODE_TYPE}"

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  azure:
    region: ${REGION}
controlPlane:
  architecture: ${OCP_ARCH}
  name: master
  platform:
    azure:
      type: ${master_type}
compute:
- architecture: ${OCP_ARCH}
  name: worker
  replicas: ${workers}
  platform:
    azure:
      type: ${COMPUTE_NODE_TYPE}
EOF

if [ -z "${OUTBOUND_TYPE}" ]; then
  echo "Outbound Type is not defined"
else
  if [ X"${OUTBOUND_TYPE}" == X"UserDefinedRouting" ] || [ X"${OUTBOUND_TYPE}" == X"NatGateway" ]; then
    echo "Writing 'outboundType: ${OUTBOUND_TYPE}' to install-config"
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

printf '%s' "${USER_TAGS:-}" | while read -r TAG VALUE
do
  printf 'Setting user tag %s: %s\n' "${TAG}" "${VALUE}"
  yq-go write -i "${CONFIG}" "platform.azure.userTags.${TAG}" "${VALUE}"
done

version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
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
