#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# mirror registry
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
if [ ! -f "${install_config_icsp_patch}" ]; then
    echo "File ${install_config_icsp_patch} does not exist."
    exit 1
fi

echo -e "image registry:\n$(cat ${install_config_icsp_patch})"

# mirror registry credential
OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
MIRROR_REGISTRY_HOST="${OMR_HOST_NAME}:8443"

mirror_registry_pull_secret=`mktemp`
registry_cred="cXVheTpwYXNzd29yZA=="
echo '{"auths":{}}' | jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' > "${mirror_registry_pull_secret}"

# Additional CA & pull secret patch
CONFIG_PATCH="${SHARED_DIR}/pull_secret_ca.yaml.patch"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
cat ${SHARED_DIR}/rootCA.pem > "${additional_trust_bundle}"
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  echo >> "${additional_trust_bundle}"
  cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" >> "${additional_trust_bundle}"
fi
cat > "${CONFIG_PATCH}" << EOF
pullSecret: >
  $(cat "${mirror_registry_pull_secret}" | jq -c .)
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

# imageContentSources patch
yq-go m -x -i "${CONFIG}" "${install_config_icsp_patch}"

rm -f "${mirror_registry_pull_secret}"