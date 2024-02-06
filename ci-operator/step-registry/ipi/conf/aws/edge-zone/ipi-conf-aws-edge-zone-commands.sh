#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${ARTIFACT_DIR}/install-config-edge-zone.yaml.patch"

edge_zones=""
while IFS= read -r line; do
  if [[ -z "${edge_zones}" ]]; then
    edge_zones="$line";
  else
    edge_zones+=",$line";
  fi
done < <(grep -v '^$' < "${SHARED_DIR}"/edge-zone-names.txt)

edge_zones_str="[ $edge_zones ]"
echo "Selected Local Zone: ${edge_zones_str}"

cat <<EOF > "${PATCH}"
compute:
- name: edge
  architecture: amd64
  hyperthreading: Enabled
  replicas: ${EDGE_NODE_WORKER_NUMBER}
  platform:
    aws:
      zones: ${edge_zones_str}
EOF

if [[ ${EDGE_NODE_INSTANCE_TYPE} != "" ]]; then
  echo "EDGE_NODE_INSTANCE_TYPE: ${EDGE_NODE_INSTANCE_TYPE}"
  echo "      type: ${EDGE_NODE_INSTANCE_TYPE}" >> ${PATCH}
else
  echo "EDGE_NODE_INSTANCE_TYPE: Empty, will be determined by installer"
fi

if [[ -e "${SHARED_DIR}/edge_zone_subnet_id" ]]; then
  edge_zone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
  ID_PATCH=$(mktemp)
  cat <<EOF > ${ID_PATCH}
platform:
  aws:
    subnets:
      - ${edge_zone_subnet_id}
EOF
  yq-go m -i -a "${PATCH}" "${ID_PATCH}"
fi

echo "Local Zone config patch:"
cat ${PATCH}

yq-go m -i -a "${CONFIG}" "${PATCH}"
