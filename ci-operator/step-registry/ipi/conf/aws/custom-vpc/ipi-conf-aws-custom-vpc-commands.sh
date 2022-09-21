#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

# subnet and AZs
all_subnet_ids="${SHARED_DIR}/all_subnet_ids"
availability_zones="${SHARED_DIR}/availability_zones"
if [ ! -f "${all_subnet_ids}" ] || [ ! -f "${availability_zones}" ]; then
    echo "File ${all_subnet_ids} or ${availability_zones} does not exist."
    exit 1
fi

echo -e "subnets: $(cat ${all_subnet_ids})"
echo -e "AZs: $(cat ${availability_zones})"

CONFIG_PATCH="${SHARED_DIR}/install-config-subnet-azs.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
platform:
  aws:
    subnets: $(cat "${all_subnet_ids}")
controlPlane:
  platform:
    aws:
      zones: $(cat "${availability_zones}")
compute:
- platform:
    aws:
      zones: $(cat "${availability_zones}")
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
