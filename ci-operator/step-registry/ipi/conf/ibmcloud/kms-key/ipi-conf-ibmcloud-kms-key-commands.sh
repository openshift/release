#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "ControlPlane EncryptionKey: ${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}"
echo "Compute EncryptionKey: ${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}"
echo "DefaultMachinePlatform EncryptionKey: ${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}"

key_file="${SHARED_DIR}/ibmcloud_key.json"

cat ${key_file}

resource_group=$(jq -r .resource_group ${key_file})

# Set EncryptionKey for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-ibmcloud-kpkey.yaml.patch"
if [[ "${IBMCLOUD_CONTROL_PLANE_ENCRYPTION_KEY}" == "true" ]]; then
    crn_master=$(jq -r .master.keyCRN ${key_file})
    if [[ -z ${crn_master} ]]; then
        echo "ERROR: fail to get the crn info of the master key in ${key_file} !!"
        exit 1
    fi
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    ibmcloud:
      bootVolume:
        encryptionKey: "${crn_master}"
EOF
fi

#Set EncryptionKey for compute nodes
if [[ "${IBMCLOUD_COMPUTE_ENCRYPTION_KEY}" == "true" ]]; then
    crn_worker=$(jq -r .worker.keyCRN ${key_file})
    if [[ -z ${crn_worker} ]]; then
        echo "ERROR: fail to get the crn info of the worker key in ${key_file} !!"
        exit 1
    fi
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    ibmcloud:
      bootVolume:
        encryptionKey: "${crn_worker}"
EOF
fi

# Set EncryptionKey under defaultMachinePlatform, applied to all nodes
if [[ "${IBMCLOUD_DEFAULT_MACHINE_ENCRYPTION_KEY}" == "true" ]]; then
    crn_default=$(jq -r .default.keyCRN ${key_file})
    if [[ -z ${crn_default} ]]; then
        echo "ERROR: fail to get the crn info of the default key in ${key_file} !!"
        exit 1
    fi
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  ibmcloud:
    defaultMachinePlatform:
      bootVolume:
        encryptionKey: "${crn_default}"
EOF
fi

cat >> "${CONFIG_PATCH}" << EOF
platform:
  ibmcloud:
    resourceGroupName: ${resource_group}
EOF

cat ${CONFIG_PATCH}
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
