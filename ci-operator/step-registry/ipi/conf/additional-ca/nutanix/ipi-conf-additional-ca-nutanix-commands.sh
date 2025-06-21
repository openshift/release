#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${CLUSTER_PROFILE_DIR}/prismcentral.pem" ]]; then
    CONFIG="${SHARED_DIR}/install-config.yaml"
    CONFIG_PATCH="/tmp/prismcentral_ca.yaml.patch"
    additional_trust_bundle="${SHARED_DIR}/additional_trust_bundle"
    echo >>"${additional_trust_bundle}"
    cat "${CLUSTER_PROFILE_DIR}"/prismcentral.pem >>"${additional_trust_bundle}"
    cat >"${CONFIG_PATCH}" <<EOF
additionalTrustBundlePolicy: "Always"
additionalTrustBundle: |
$(sed 's/^/  /g' "${additional_trust_bundle}")
EOF
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
fi
