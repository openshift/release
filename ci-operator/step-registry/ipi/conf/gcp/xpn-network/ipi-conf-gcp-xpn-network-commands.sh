#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

echo "Reading variables from 'xpn_project_setting.json'..."
HOST_PROJECT=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_COMPUTE_SUBNET=$(jq -r '.computeSubnet' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
HOST_PROJECT_CONTROL_SUBNET=$(jq -r '.controlSubnet' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
NETWORK=$(basename ${HOST_PROJECT_NETWORK})
CONTROL_SUBNET=$(basename ${HOST_PROJECT_CONTROL_SUBNET})
COMPUTE_SUBNET=$(basename ${HOST_PROJECT_COMPUTE_SUBNET})
cat > "${PATCH}" << EOF
platform:
  gcp:
    networkProjectID: ${HOST_PROJECT}
    network: ${NETWORK}
    controlPlaneSubnet: ${CONTROL_SUBNET}
    computeSubnet: ${COMPUTE_SUBNET}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated GCP network settings."

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
