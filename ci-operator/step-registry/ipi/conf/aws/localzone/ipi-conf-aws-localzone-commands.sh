#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

localzone_subnet_id=$(head -n 1 "${SHARED_DIR}/localzone_subnet_id")
PATCH="${ARTIFACT_DIR}/install-config-local-zone.yaml.patch"
cat <<EOF > ${PATCH}
compute:
- name: edge
  architecture: amd64
  hyperthreading: Enabled
  replicas: ${LOCALZONE_WORKER_NUMBER}
  platform:
    aws:
      type: ${LOCALZONE_INSTANCE_TYPE}
platform:
  aws:
    subnets:
      - ${localzone_subnet_id}
EOF
yq-go m -i -a "${CONFIG}" "${PATCH}"

