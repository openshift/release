#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

provisioned_rg_file="${SHARED_DIR}/resourcegroup"
provisioned_des_file="${SHARED_DIR}/azure_des"
subscription_id="$(<"${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" jq -r .subscriptionId)"

if [ ! -f "${provisioned_rg_file}" ]; then
    echo "${provisioned_rg_file} is not found, exiting..."
    exit 1
else
    rg=$(< "${provisioned_rg_file}")
    echo "using existing resource group - ${rg}"
fi

if [ ! -f "${provisioned_des_file}" ]; then
    echo "${provisioned_des_file} is not found, exiting..."
    exit 1
else
    des=$(< "${provisioned_des_file}")
    echo "using existing azure des - ${des}"
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-provisioned-des.yaml.patch"

# create a patch with existing des
if [[ "${ENABLE_DES_DEFAULT_MACHINE}" == "true" ]]; then
  cat > "${PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      encryptionAtHost: true
      osDisk:
        diskEncryptionSet:
          resourceGroup: ${rg}
          name: ${des}
          subscriptionId: ${subscription_id}
EOF
else
  cat > "${PATCH}" << EOF
compute:
- platform:
    azure:
      encryptionAtHost: true
      osDisk:
        diskEncryptionSet:
          resourceGroup: ${rg}
          name: ${des}
          subscriptionId: ${subscription_id}
controlPlane:
  platform:
    azure:
      encryptionAtHost: true
      osDisk:
        diskEncryptionSet:
          resourceGroup: ${rg}
          name: ${des}
          subscriptionId: ${subscription_id}
EOF
fi

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
