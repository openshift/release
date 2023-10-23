#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"
subnet_ids_file="${SHARED_DIR}/subnet_ids"
az_file="${SHARED_DIR}/availability_zones"

if [ ! -f "${subnet_ids_file}" ] || [ ! -f "${az_file}" ]; then
  echo "File ${subnet_ids_file} or ${az_file} does not exist."
  exit 1
fi

echo -e "subnets: $(cat ${subnet_ids_file})"
echo -e "AZs: $(cat ${az_file})"

CONFIG_SUBNETS="${SHARED_DIR}/install-config-subnet.yaml.patch"
cat > "${CONFIG_SUBNETS}" << EOF
platform:
  aws:
    subnets: $(cat "${subnet_ids_file}")
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_SUBNETS}"


if [[ ${ADD_ZONES} == "yes" ]]; then
  CONFIG_AZ="${SHARED_DIR}/install-config-azs.yaml.patch"
  cat > "${CONFIG_AZ}" << EOF
controlPlane:
  platform:
    aws:
      zones: $(cat "${az_file}")
compute:
- platform:
    aws:
      zones: $(cat "${az_file}")
EOF
  yq-go m -x -i "${CONFIG}" "${CONFIG_AZ}"
fi
