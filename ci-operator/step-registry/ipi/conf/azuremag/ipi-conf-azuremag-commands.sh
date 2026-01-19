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
master_type=Standard_E4s_v3
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type=Standard_E32_v3
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type=Standard_E16_v3
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type=Standard_E8_v3
fi

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
  OUTBOUND_TYPE_VALUE="UserDefinedRouting NATGatewaySingleZone NATGatewayMultiZone NatGateway"
  #shellcheck disable=SC2076
  if [[ " ${OUTBOUND_TYPE_VALUE} " =~ " ${OUTBOUND_TYPE} " ]]; then
    echo "Writing 'outboundType: ${OUTBOUND_TYPE}' to install-config"
    PATCH="${SHARED_DIR}/install-config-outboundType.yaml.patch"
    cat > "${PATCH}" << EOF
platform:
  azure:
    outboundType: ${OUTBOUND_TYPE}
EOF
    yq-go m -x -i "${CONFIG}" "${PATCH}"
  else
    echo "${OUTBOUND_TYPE} is not supported yet" && exit 1
  fi
fi
