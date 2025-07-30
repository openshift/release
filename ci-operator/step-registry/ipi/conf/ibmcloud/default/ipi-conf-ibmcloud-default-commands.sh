#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "IBMCloud region: ${REGION}"

workers=${WORKERS:-3}
if [ "${workers}" -le 0 ]; then
  workers=0
fi
PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  ibmcloud:
    region: ${REGION}
controlPlane:
  name: master
  platform: {}
compute:
- name: worker
  replicas: ${workers}
  platform: {}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
