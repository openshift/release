#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="${SHARED_DIR}/install-config-identity-patch.yaml"

identity_json_file="${SHARED_DIR}/azure_user_assigned_identity.json"

end_number=$((AZURE_USER_ASSIGNED_IDENTITY_NUMBER - 1))
if [[ "${ENABLE_AZURE_IDENTITY_DEFAULT_MACHINE}" == "true" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      identity:
        type: UserAssigned
        userAssignedIdentities:
EOF
    for num in $(seq 0 ${end_number}); do
        cat >> "${CONFIG_PATCH}" << EOF
        - name: $(jq -r ".identityDefault[$num].name" ${identity_json_file})
          subscription: $(jq -r ".identityDefault[$num].subscription" ${identity_json_file})
          resourceGroup: $(jq -r ".identityDefault[$num].resourceGroup" ${identity_json_file})
EOF
    done
fi

if [[ "${ENABLE_AZURE_IDENTITY_CONTROL_PLANE}" == "true" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      identity:
        type: UserAssigned
        userAssignedIdentities:
EOF
    for num in $(seq 0 ${end_number}); do
        cat >> "${CONFIG_PATCH}" << EOF
        - name: $(jq -r ".identityControlPlane[$num].name" ${identity_json_file})
          subscription: $(jq -r ".identityControlPlane[$num].subscription" ${identity_json_file})
          resourceGroup: $(jq -r ".identityControlPlane[$num].resourceGroup" ${identity_json_file})
EOF
    done
fi

if [[ "${ENABLE_AZURE_IDENTITY_COMPUTE}" == "true" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      identity:
        type: UserAssigned
        userAssignedIdentities:
EOF
    for num in $(seq 0 ${end_number}); do
        cat >> "${CONFIG_PATCH}" << EOF
        - name: $(jq -r ".identityCompute[$num].name" ${identity_json_file})
          subscription: $(jq -r ".identityCompute[$num].subscription" ${identity_json_file})
          resourceGroup: $(jq -r ".identityCompute[$num].resourceGroup" ${identity_json_file})
EOF
    done
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi
