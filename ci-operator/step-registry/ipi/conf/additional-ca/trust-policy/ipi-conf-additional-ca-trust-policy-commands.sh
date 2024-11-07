#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

CONFIG_PATCH="/tmp/additional_ca_policy.yaml.patch"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
cat /var/run/vault/mirror-registry/client_ca.crt >> "${additional_trust_bundle}"

if [[ ${ADDITIONAL_TRUST_BUNDLE_POLICY} != "" && ${ADDITIONAL_TRUST_BUNDLE_POLICY} != "Proxyonly" && ${ADDITIONAL_TRUST_BUNDLE_POLICY} != "Always" ]]; then
  echo "Error: invalid value for additionalTrustBundlePolicy set!"
  exit 1
fi

cat > "${CONFIG_PATCH}" << EOF
additionalTrustBundlePolicy: "${ADDITIONAL_TRUST_BUNDLE_POLICY}"
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
