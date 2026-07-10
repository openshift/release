#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

# mirror registry
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
if [ ! -f "${install_config_mirror_patch}" ]; then
    echo "File ${install_config_mirror_patch} does not exist."
    exit 1
fi

echo -e "image registry:\n$(cat ${install_config_mirror_patch})"

# mirror registry credential
if [[ ! -s "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist or is empty."
    exit 1
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")

runtime_registry_creds="${SHARED_DIR}/mirror_registry_creds"
if [[ -s "${runtime_registry_creds}" ]]; then
    registry_creds_file="${runtime_registry_creds}"
    echo "Using runtime mirror registry credentials from SHARED_DIR."
else
    registry_creds_file="/var/run/vault/mirror-registry/registry_creds"
    echo "Using the configured mirror registry credential fallback."
fi
mirror_registry_pull_secret=$(mktemp)
registry_cred=$(head -n 1 "${registry_creds_file}" | base64 -w 0)
echo '{"auths":{}}' | jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" \
  '.auths |= . + $a' > "${mirror_registry_pull_secret}"

# Additional CA & pull secret patch
CONFIG_PATCH="${SHARED_DIR}/pull_secret_ca.yaml.patch"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
runtime_registry_ca="${SHARED_DIR}/mirror_registry_ca.crt"
if [[ -s "${runtime_registry_ca}" ]]; then
    echo >> "${additional_trust_bundle}"
    cat "${runtime_registry_ca}" >> "${additional_trust_bundle}"
elif [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
    echo >> "${additional_trust_bundle}"
    cat "${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt" >> "${additional_trust_bundle}"
else
    echo >> "${additional_trust_bundle}"
    cat /var/run/vault/mirror-registry/client_ca.crt >> "${additional_trust_bundle}"
fi

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
yq-go m -x -i "${CONFIG}" "${install_config_mirror_patch}"

# Add sourcePolicy to imageDigestSources if specified
if [[ "${ENABLE_IDMS:-}" == "yes" ]] && [[ -n "${IDMS_SOURCE_POLICY:-}" ]]; then
  echo "Adding sourcePolicy: ${IDMS_SOURCE_POLICY} to imageDigestSources"

  num_sources="0"
  num_sources=$(yq-go r "${CONFIG}" 'imageDigestSources' -l)

  for ((i=0; i<num_sources; i++)); do
    echo "Updated imageDigestSources item - $i with sourcePolicy: ${IDMS_SOURCE_POLICY}"
    yq-go w -i "${CONFIG}" "imageDigestSources[$i].sourcePolicy" "${IDMS_SOURCE_POLICY}"
  done

  yq-go r "${CONFIG}" 'imageDigestSources'
fi

rm -f "${mirror_registry_pull_secret}"
