#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

ca_bundle="${SHARED_DIR}/azure_il6_ca_bundle"
if [[ ! -s "${ca_bundle}" ]]; then
    echo "ERROR: ${ca_bundle} not found or empty."
    echo "azure-il6-bastion-ca writes this file and must run before this step."
    exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

# ${SHARED_DIR}/additional_trust_bundle is a shared accumulator, not a private file: ipi-conf-mirror
# appends the mirror registry's CA to it and then writes the WHOLE file into install-config as
# additionalTrustBundle. Writing additionalTrustBundle directly here would be silently overwritten
# by whichever of the two steps ran last. Appending to the accumulator and then publishing it makes
# the two steps order-independent -- each one publishes a superset of what the other did.
#
# The same pattern already exists upstream: ipi-conf-mirror appends shift-ca-chain.cert.pem for the
# aws-sc2s/aws-c2s cluster types.
accumulator="${SHARED_DIR}/additional_trust_bundle"

appended_marker="${SHARED_DIR}/.azure_il6_ca_appended"
if [[ -f "${appended_marker}" ]]; then
    echo "SHIFT CA already appended to ${accumulator} by an earlier invocation."
else
    echo >> "${accumulator}"
    cat "${ca_bundle}" >> "${accumulator}"
    touch "${appended_marker}"
fi

CONFIG_PATCH="${SHARED_DIR}/install-config-additional-ca-azureil6.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
additionalTrustBundlePolicy: "Always"
additionalTrustBundle: |
$(sed 's/^/  /g' "${accumulator}")
EOF

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
rm -f "${CONFIG_PATCH}"

echo "additionalTrustBundle now carries $(grep -c 'BEGIN CERTIFICATE' "${accumulator}") certificate(s)."
