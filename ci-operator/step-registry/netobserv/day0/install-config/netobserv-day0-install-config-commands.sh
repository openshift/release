#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} not found. This step must run after ipi-conf-aws." >&2
    exit 1
fi

echo "Patching networking.networkObservability.installationPolicy=${NETOBSERV_INSTALLATION_POLICY}"
yq eval ".networking.networkObservability.installationPolicy = \"${NETOBSERV_INSTALLATION_POLICY}\"" -i "${CONFIG}"

echo "Resulting networking.networkObservability section:"
yq eval '.networking.networkObservability' "${CONFIG}"

# Save to artifacts for debugging
yq eval '.networking.networkObservability' "${CONFIG}" > "${ARTIFACT_DIR}/install-config-netobserv-sections.yaml"
