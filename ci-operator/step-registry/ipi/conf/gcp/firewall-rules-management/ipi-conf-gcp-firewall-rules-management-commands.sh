#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

if [[ "${FILEWALL_RULES_MANAGEMENT}" == "Unmanaged" ]]; then
  cat > "${PATCH}" << EOF
platform:
  gcp:
    firewallRulesManagement: ${FILEWALL_RULES_MANAGEMENT}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated firewallRulesManagement in '${CONFIG}'."
fi

IFS=', ' read -r -a array <<< "${NETWORK_TAGS_FOR_COMPUTE_NODES}"
if [ "${#array[@]}" -gt 0 ]; then
  cat > "${PATCH}" << EOF
compute:
- platform:
    gcp:
      tags:
EOF
  for tag in "${array[@]}"; do
    cat >> "${PATCH}" << EOF
      - ${tag}
EOF
  done
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute.platform.gcp.tags in '${CONFIG}'."
fi

IFS=', ' read -r -a array <<< "${NETWORK_TAGS_FOR_CONTROL_PLANE_NODES}"
if [[ "${#array[@]}" -gt 0 ]]; then
  cat > "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      tags:
EOF
  for tag in "${array[@]}"; do
    cat >> "${PATCH}" << EOF
      - ${tag}
EOF
  done
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated controlPlane.platform.gcp.tags in '${CONFIG}'."
fi

echo "(debug)--------------------"
yq-go r "${CONFIG}" platform
echo "(debug)--------------------"
yq-go r "${CONFIG}" compute
echo "(debug)--------------------"
yq-go r "${CONFIG}" controlPlane
echo "(debug)--------------------"
