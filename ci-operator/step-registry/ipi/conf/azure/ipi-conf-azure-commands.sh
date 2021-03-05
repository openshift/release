#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=null
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=Standard_D32s_v3
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=Standard_D16s_v3
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=Standard_D8s_v3
fi

cat >> "${CONFIG}" << EOF
baseDomain: ci.azure.devcluster.openshift.com
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${REGION}
controlPlane:
  name: master
  platform:
    azure:
      type: ${master_type}
compute:
- name: worker
  replicas: ${workers}
  platform:
    azure:
      type: ${COMPUTE_NODE_TYPE}
EOF
