#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

CONFIG_PATCH="/tmp/additional_ca_policy.yaml.patch"

additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"

if [[ $CLUSTER_TYPE == "nutanix" ]]; then
  if [[ -f "${CLUSTER_PROFILE_DIR}/prismcentral.pem" ]]; then
    cat "${CLUSTER_PROFILE_DIR}"/prismcentral.pem >> "${additional_trust_bundle}"
  fi
else
  if [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt" >> "${additional_trust_bundle}"
  else
    cat /var/run/vault/mirror-registry/client_ca.crt >> "${additional_trust_bundle}"
  fi
fi

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
