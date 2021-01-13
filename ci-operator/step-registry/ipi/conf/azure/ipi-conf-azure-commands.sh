#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

cat >> "${CONFIG}" << EOF
baseDomain: ci.azure.devcluster.openshift.com
compute:
- name: worker
  platform:
    azure:
      type: ${COMPUTE_NODE_TYPE}
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${REGION}
EOF
