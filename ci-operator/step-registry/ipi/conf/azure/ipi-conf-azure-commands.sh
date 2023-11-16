#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "get ocp version: ${version}"
rm pull-secret
popd

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=${COMPUTE_NODE_REPLICAS:-3}
if [ "${COMPUTE_NODE_REPLICAS}" -le 0 ] || [ "${SIZE_VARIANT}" = "compact" ]; then
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
