#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "Write the 'baseDomainResourceGroupName: os4-common' to install-config"
PATCH="${SHARED_DIR}/install-config-baseDomainRG.yaml.patch"
cat > "${PATCH}" << EOF
platform:
  azure:
    baseDomainResourceGroupName: os4-common
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

#make sure the baseDomainResourceGroupName is set to os4-common in install-config.yaml file for azure platform 
fgrep 'baseDomainResourceGroupName: os4-common' ${CONFIG}
if [ $? -ne 0 ]; then
    echo "baseDomainResourceGroupName is not set to os4-common in install-config.yaml"
    exit 1
fi
