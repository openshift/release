#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"
subnet_ids_file="${SHARED_DIR}/subnet_ids"
zone_names_region_file="${SHARED_DIR}/zone_names_region"

if [ ! -f "${subnet_ids_file}" ]; then
  echo "File ${subnet_ids_file} does not exist."
  exit 1
fi

echo -e "subnets: $(cat "${subnet_ids_file}")"
echo -e "zone names: $(cat "${zone_names_region_file}")"

ZONES_REGION_STR=$(cat "${zone_names_region_file}")

CONFIG_PATCH="${SHARED_DIR}/install-config-subnets.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_REGION_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_REGION_STR}
platform:
  aws:
    subnets: $(cat "${subnet_ids_file}")
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

cp "${CONFIG_PATCH}" "${ARTIFACT_DIR}/"