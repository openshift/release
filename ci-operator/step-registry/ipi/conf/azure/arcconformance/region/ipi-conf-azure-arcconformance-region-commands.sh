#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO remove this step once Arc is available in more regions.

# if the env var wasn't provided we stick to the leased region
if [[ -z "$AZURE_REGION" ]]; then
  exit 0
fi

if [[ "$LEASED_RESOURCE" == "$AZURE_REGION" ]]; then
  exit 0
fi

echo "================================================"
echo "Azure Arc-enabled Kubernetes clusters are not" 
echo "available in ${LEASED_RESOURCE}."
echo "Patching region to ${AZURE_REGION}..."
echo "================================================"

CONFIG="${SHARED_DIR}/install-config.yaml"
COMPUTE_NODE_TYPE="Standard_D4s_v3"

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
    region: ${AZURE_REGION}
EOF
