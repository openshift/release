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
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
mirror_registry_pull_secret=`mktemp`
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
echo '{"auths":{}}' | jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' > "${mirror_registry_pull_secret}"

# Additional CA & pull secret patch
CONFIG_PATCH="${SHARED_DIR}/pull_secret_ca.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
pullSecret: >
  $(cat "${mirror_registry_pull_secret}" | jq -c .)
additionalTrustBundle: |
`sed 's/^/  /g' "/var/run/vault/mirror-registry/client_ca.crt"`
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

# imageContentSources patch
yq-go m -x -i "${CONFIG}" "${install_config_icsp_patch}"

rm -f "${mirror_registry_pull_secret}"
