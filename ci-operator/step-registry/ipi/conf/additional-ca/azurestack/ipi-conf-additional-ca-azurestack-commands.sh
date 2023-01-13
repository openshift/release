#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="/tmp/additional_ca.yaml.patch"
additional_trust_bundle="${CLUSTER_PROFILE_DIR}/ca.pem"

cat > "${CONFIG_PATCH}" << EOF
additionalTrustBundlePolicy: "Always"
additionalTrustBundle: |
`sed 's/^/  /g' "${additional_trust_bundle}"`
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
