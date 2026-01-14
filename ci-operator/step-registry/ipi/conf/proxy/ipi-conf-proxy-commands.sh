#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/proxy_private_url" ]]; then
  echo "'${SHARED_DIR}/proxy_private_url' not found, abort." && exit 1
fi

CONFIG_PATCH="${SHARED_DIR}/proxy.yaml.patch"
CONFIG="${SHARED_DIR}/install-config.yaml"

proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")

cat > "${CONFIG_PATCH}" << EOF
proxy:
  httpProxy: ${proxy_private_url}
EOF

if [[ "${ENABLE_HTTPS_PROXY}" == "yes" ]]; then
  if [[ ! -f "${SHARED_DIR}/proxy_private_https_url" ]]; then
    echo "'${SHARED_DIR}/proxy_private_https_url' not found, abort." && exit 1
  fi
  proxy_private_https_url=$(< "${SHARED_DIR}/proxy_private_https_url")
  cat >> "${CONFIG_PATCH}" << EOF
  httpsProxy: ${proxy_private_https_url}
EOF
  additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
  client_ca_file="/var/run/vault/mirror-registry/client_ca.crt"
  if ! grep -Fqz "$(cat "$client_ca_file")" "${additional_trust_bundle}" 2>/dev/null; then
    cat "$client_ca_file" >> "${additional_trust_bundle}"
    cat >> "${CONFIG_PATCH}" << EOF
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF
  else
    echo "CA certificate already present in ${additional_trust_bundle}"
  fi
else
  cat >> "${CONFIG_PATCH}" << EOF
  httpsProxy: ${proxy_private_url}
EOF
fi

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
