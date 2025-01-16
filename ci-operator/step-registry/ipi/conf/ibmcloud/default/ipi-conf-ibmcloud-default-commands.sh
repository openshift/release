#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=${WORKERS:-3}
if [ "${WORKERS}" -le 0 ]; then
  workers=0
fi
ocp_arch="amd64"
PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  ibmcloud:
    baseDomainResourceGroupName: ${BASE_DOMAIN_RESOURCE_GROUP}
    region: ${REGION}
controlPlane:
  architecture: ${ocp_arch}
  name: master
  platform: {}
compute:
- architecture: ${ocp_arch}
  name: worker
  replicas: ${workers}
  platform: {}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
