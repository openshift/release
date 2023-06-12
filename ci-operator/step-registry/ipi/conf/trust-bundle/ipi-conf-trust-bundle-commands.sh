#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# Additional CA & pull secret patch
CONFIG_PATCH="${SHARED_DIR}/pull_secret_ca.yaml.patch"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
cat /var/run/vault/mirror-registry/client_ca.crt > "${additional_trust_bundle}"
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  echo >> "${additional_trust_bundle}"
  cat "${CLUSTER_PROFILE_DIR}/shift-ca-chain.cert.pem" >> "${additional_trust_bundle}"
fi
cat > "${CONFIG_PATCH}" << EOF
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
