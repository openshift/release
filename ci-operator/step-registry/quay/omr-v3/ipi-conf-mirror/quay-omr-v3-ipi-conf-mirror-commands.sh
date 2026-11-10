#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
mirror_registry_pull_secret=""

cleanup() {
  local status="$?"

  trap - EXIT TERM
  if [[ "${status}" -eq 0 ]]; then
    EXIT_CODE=0
  fi
  if [[ -n "${mirror_registry_pull_secret}" ]]; then
    rm -f -- "${mirror_registry_pull_secret}"
  fi
  printf '%s\n' "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
  exit "${status}"
}

terminate() {
  exit 143
}

trap cleanup EXIT
trap terminate TERM

config="${SHARED_DIR}/install-config.yaml"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
runtime_registry_url="${SHARED_DIR}/mirror_registry_url"
runtime_registry_creds="${SHARED_DIR}/mirror_registry_creds"
runtime_registry_ca="${SHARED_DIR}/mirror_registry_ca.crt"

for required_file in \
  "${config}" \
  "${install_config_mirror_patch}" \
  "${runtime_registry_url}" \
  "${runtime_registry_creds}" \
  "${runtime_registry_ca}"; do
  if [[ ! -s "${required_file}" ]]; then
    echo "Required OMR input ${required_file} does not exist or is empty."
    exit 1
  fi
done

mirror_registry_host=$(head -n 1 "${runtime_registry_url}")
# Docker auth encodes username:password without the credential file's newline.
registry_credentials=$(tr -d '\r\n' < "${runtime_registry_creds}")
if [[ -z "${registry_credentials}" || "${registry_credentials}" != *:* ]]; then
  echo "The runtime OMR credential is invalid."
  exit 1
fi
registry_cred=$(printf '%s' "${registry_credentials}" | base64 -w 0)
unset registry_credentials

umask 077
mirror_registry_pull_secret=$(mktemp /tmp/quay-omr-v3-pull-secret.XXXXXX)
jq -n --arg host "${mirror_registry_host}" --arg auth "${registry_cred}" \
  '{auths: {($host): {auth: $auth}}}' > "${mirror_registry_pull_secret}"
chmod 0600 "${mirror_registry_pull_secret}"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
{
  echo
  cat "${runtime_registry_ca}"
} >> "${additional_trust_bundle}"

config_patch="${SHARED_DIR}/pull_secret_ca.yaml.patch"
cat > "${config_patch}" <<EOF
pullSecret: >
  $(jq -c . "${mirror_registry_pull_secret}")
additionalTrustBundle: |
$(sed 's/^/  /g' "${additional_trust_bundle}")
EOF

yq-go m -x -i "${config}" "${config_patch}"
yq-go m -x -i "${config}" "${install_config_mirror_patch}"

case "${IDMS_SOURCE_POLICY}" in
  NeverContactSource|AllowContactingSource)
    ;;
  *)
    echo "Unsupported IDMS source policy: ${IDMS_SOURCE_POLICY}"
    exit 1
    ;;
esac

num_sources=$(yq-go r "${config}" 'imageDigestSources' -l)
if [[ ! "${num_sources}" =~ ^[1-9][0-9]*$ ]]; then
  echo "The generated install config contains no imageDigestSources entries."
  exit 1
fi

for ((i=0; i<num_sources; i++)); do
  yq-go w -i "${config}" "imageDigestSources[$i].sourcePolicy" "${IDMS_SOURCE_POLICY}"
done

echo "Configured ${num_sources} OMR imageDigestSources entries with sourcePolicy ${IDMS_SOURCE_POLICY}."
