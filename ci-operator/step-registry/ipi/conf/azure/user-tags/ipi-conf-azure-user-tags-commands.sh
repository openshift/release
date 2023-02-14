#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function getVersion() {
	local release_image=""
	if [[ -n "${RELEASE_IMAGE_INITIAL-}" ]]; then
		release_image=${RELEASE_IMAGE_INITIAL}
	elif [[ -n "${RELEASE_IMAGE_LATEST-}" ]]; then
		release_image=${RELEASE_IMAGE_LATEST}
	fi

	local version=""
	if [[ ${release_image} != "" ]]; then
		oc registry login > /dev/null
		version=$(oc adm release info "${release_image}" --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
	fi
	echo "${version}"
}

# userTags for Azure introduced in OCP-4.13, configuring
# platform.azure.userTags in install-config for releases
# 4.13 and above
CONFIG="${SHARED_DIR}/install-config.yaml"
OCP_AZURE_TAGS_FROM_VERSION="4.13"
version=$(getVersion)
echo "current ocp version: ${version}"
if [[ "$(printf '%s\n' "$OCP_AZURE_TAGS_FROM_VERSION" "$version" | sort -V | head -n1)" = "$OCP_AZURE_TAGS_FROM_VERSION" ]]; then
	echo "updating 'platform.azure.userTags' in install-config"
	PATCH="${SHARED_DIR}/install-config-userTags.yaml.patch"
	cat > "${PATCH}" << EOF
platform:
  azure:
    userTags:
      created-for: e2e-test
      environment: test
EOF
	yq-go m -x -i "${CONFIG}" "${PATCH}"
else
	echo "OCP version is $version, not updating platform.azure.userTags"
fi
