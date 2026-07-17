#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
if [[ ! -f "${install_config_mirror_patch}" ]]; then
    echo "File ${install_config_mirror_patch} does not exist."
    exit 1
fi

echo "Image registry mirror patch:"
cat "${install_config_mirror_patch}"

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")

if [[ -f "${SHARED_DIR}/acr_registry_creds" ]]; then
    registry_cred=$(cat "${SHARED_DIR}/acr_registry_creds" | base64 -w 0)
else
    registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
fi

mirror_registry_pull_secret=$(mktemp)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"${registry_cred}\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${mirror_registry_pull_secret}"
oc registry login --to "${mirror_registry_pull_secret}"

CONFIG_PATCH="${SHARED_DIR}/pull_secret_ca.yaml.patch"

if [[ -f "${SHARED_DIR}/acr_registry_creds" ]]; then
    cat > "${CONFIG_PATCH}" <<EOF
pullSecret: >
  $(cat "${mirror_registry_pull_secret}" | jq -c .)
EOF
else
    additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
    echo >> "${additional_trust_bundle}"
    cat /var/run/vault/mirror-registry/client_ca.crt >> "${additional_trust_bundle}"

    cat > "${CONFIG_PATCH}" <<EOF
pullSecret: >
  $(cat "${mirror_registry_pull_secret}" | jq -c .)
additionalTrustBundle: |
$(sed 's/^/  /g' "${additional_trust_bundle}")
EOF
fi

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
yq-go m -x -i "${CONFIG}" "${install_config_mirror_patch}"

rm -f "${mirror_registry_pull_secret}"