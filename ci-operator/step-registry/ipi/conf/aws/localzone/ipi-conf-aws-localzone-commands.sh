#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${ARTIFACT_DIR}/install-config-edge-zone.yaml.patch"

edge_zone=$(< "${SHARED_DIR}"/edge-zone-name.txt)
edge_zones_str="[ $edge_zone ]"

echo "Selected Local Zone: ${edge_zone}"
echo "edge_zones_str: ${edge_zones_str}"
cat <<EOF > "${PATCH}"
compute:
- name: edge
  architecture: amd64
  hyperthreading: Enabled
  replicas: ${LOCALZONE_WORKER_NUMBER}
  platform:
    aws:
      zones: ${edge_zones_str}
EOF

if [[ ${LOCALZONE_INSTANCE_TYPE} != "" ]]; then
  echo "LOCALZONE_INSTANCE_TYPE: ${LOCALZONE_INSTANCE_TYPE}"
  echo "      type: ${LOCALZONE_INSTANCE_TYPE}" >> ${PATCH}
else
  echo "LOCALZONE_INSTANCE_TYPE: Empty, will be determined by installer"
fi

# use localzone id
if [[ -e "${SHARED_DIR}/edge_zone_subnet_id" ]]; then
  localzone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
  ID_PATCH=$(mktemp)
  cat <<EOF > ${ID_PATCH}
platform:
  aws:
    subnets:
      - ${localzone_subnet_id}
EOF
  yq-go m -i -a "${PATCH}" "${ID_PATCH}"
fi

echo "Local Zone config patch:"
cat ${PATCH}

yq-go m -i -a "${CONFIG}" "${PATCH}"
