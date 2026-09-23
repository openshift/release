#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GCP_REGION="${LEASED_RESOURCE}"

workers=${COMPUTE_NODE_REPLICAS:-3}
if [ "${COMPUTE_NODE_REPLICAS}" -le 0 ]; then
  workers=0
fi

if [[ ${OCP_ARCH} != "amd64" ]] && [[ ${OCP_ARCH} != "arm64" ]]; then
  echo "Error: architecture \"${OCP_ARCH}\" is not supported, valid values: amd64, arm64. Exit now."
  exit 1
fi


PATCH="${SHARED_DIR}/install-config-common.yaml.patch"

cat > "${PATCH}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
controlPlane:
  architecture: ${OCP_ARCH}
  name: master
  platform: {}
compute:
- architecture: ${OCP_ARCH}
  name: worker
  replicas: ${workers}
  platform: {}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
