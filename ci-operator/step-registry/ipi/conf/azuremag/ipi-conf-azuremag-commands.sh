#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi
master_type=Standard_E4s_v3
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=Standard_E32_v3
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=Standard_E16_v3
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=Standard_E8_v3
fi

cp "/var/run/cluster-secrets-azuremag-qe/osServicePrincipal.json" "${SHARED_DIR}/osServicePrincipal.json"

cat >> "${CONFIG}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${REGION}
    cloudName: AzureUSGovernmentCloud
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

if [ -z "${OUTBOUND_TYPE}" ]; then
  echo "Outbound Type is not defined"
else
  if [ X"${OUTBOUND_TYPE}" == X"UserDefinedRouting" ]; then
    echo "Writing 'outboundType: UserDefinedRouting' to install-config"
    PATCH="${SHARED_DIR}/install-config-outboundType.yaml.patch"
    cat > "${PATCH}" << EOF
platform:
  azure:
    outboundType: ${OUTBOUND_TYPE}
EOF
    /tmp/yq m -x -i "${CONFIG}" "${PATCH}"
  else
    echo "${OUTBOUND_TYPE} is not supported yet" || exit 1
  fi
fi
