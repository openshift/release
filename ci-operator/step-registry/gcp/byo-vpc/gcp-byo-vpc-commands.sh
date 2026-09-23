#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

network_settings_json="${CLUSTER_PROFILE_DIR}/gcp_byo_vpc_settings.json"

if [[ ! -f "${network_settings_json}" ]]; then
  ls -l "${CLUSTER_PROFILE_DIR}"
  echo "'${network_settings_json}' not found, abort." && exit 1
fi

network=$(jq -r '.network' "${network_settings_json}")
control_plane_subnet=$(jq -r '.controlPlaneSubnet' "${network_settings_json}")
compute_subnet=$(jq -r '.computeSubnet' "${network_settings_json}")

echo "$(date -u --rfc-3339=seconds) - network: ${network}"
echo "$(date -u --rfc-3339=seconds) - controlPlaneSubnet: ${control_plane_subnet}"
echo "$(date -u --rfc-3339=seconds) - computeSubnet: ${compute_subnet}"

cat > "${SHARED_DIR}/customer_vpc_subnets.yaml" << EOF
platform:
  gcp:
    network: ${network}
    controlPlaneSubnet: ${control_plane_subnet}
    computeSubnet: ${compute_subnet}
EOF
