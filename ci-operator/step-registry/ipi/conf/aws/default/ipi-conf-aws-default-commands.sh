#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ ! -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  echo "Using default value: ${BASE_DOMAIN}"
  AWS_BASE_DOMAIN="${BASE_DOMAIN}"
else
  AWS_BASE_DOMAIN=$(< ${CLUSTER_PROFILE_DIR}/baseDomain)
fi

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

REGION="${LEASED_RESOURCE}"

master_replicas=${CONTROL_PLANE_REPLICAS:-3}
worker_replicas=${COMPUTE_NODE_REPLICAS:-3}

if [[ "${COMPUTE_NODE_REPLICAS}" -le 0 ]]; then
    worker_replicas=0
fi

if [[ ${OCP_ARCH} != "amd64" ]] && [[ ${OCP_ARCH} != "arm64" ]]; then
  echo "Error: architecture \"${OCP_ARCH}\" is not supported, valid values: amd64, arm64. Exit now."
  exit 1
fi

PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${AWS_BASE_DOMAIN}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
      clusterName: ${NAMESPACE}-${UNIQUE_HASH}
controlPlane:
  architecture: ${OCP_ARCH}
  name: master
  replicas: ${master_replicas}
  platform: {}
compute:
- architecture: ${OCP_ARCH}
  name: worker
  replicas: ${worker_replicas}
  platform: {}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
