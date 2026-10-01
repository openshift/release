#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-netobserv-day0.yaml.patch"

if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: ${CONFIG} not found. This step must run after ipi-conf-aws." >&2
    exit 1
fi

echo "Generating NetObserv day0 install-config patch..."
echo "  NETOBSERV_INSTALLATION_POLICY=${NETOBSERV_INSTALLATION_POLICY}"
echo "  FEATURE_SET=${FEATURE_SET}"
echo "  FEATURE_GATES=${FEATURE_GATES}"

# Convert JSON array of feature gates to YAML list entries
FEATURE_GATES_YAML=$(echo "${FEATURE_GATES}" | python3 -c "
import sys, json
gates = json.load(sys.stdin)
for g in gates:
    print('- ' + g)
")

cat > "${PATCH}" <<EOF
featureSet: ${FEATURE_SET}
featureGates:
${FEATURE_GATES_YAML}
networking:
  networkObservability:
    installationPolicy: ${NETOBSERV_INSTALLATION_POLICY}
EOF

echo "Patch contents:"
cat "${PATCH}"

echo "Merging patch into ${CONFIG}..."
# yq v4 (mikefarah): merge PATCH into CONFIG, PATCH values take precedence (overwrite)
yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' "${CONFIG}" "${PATCH}" > "${CONFIG}.merged"
mv "${CONFIG}.merged" "${CONFIG}"

echo "Relevant install-config sections after merge:"
yq eval '.featureSet' "${CONFIG}"
yq eval '.featureGates' "${CONFIG}"
yq eval '.networking.networkObservability' "${CONFIG}"

# Save patch and merged sections to artifacts for debugging
cp "${PATCH}" "${ARTIFACT_DIR}/install-config-netobserv-day0.yaml.patch"
yq eval '{
  "featureSet": .featureSet,
  "featureGates": .featureGates,
  "networking": {"networkObservability": .networking.networkObservability}
}' "${CONFIG}" > "${ARTIFACT_DIR}/install-config-netobserv-sections.yaml"
