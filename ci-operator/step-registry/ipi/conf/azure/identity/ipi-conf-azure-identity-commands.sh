#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="${SHARED_DIR}/install-config-identity-patch.yaml"

identity_json_file="${SHARED_DIR}/azure_user_assigned_identity.json"

end_number=$((AZURE_USER_ASSIGNED_IDENTITY_NUMBER - 1))
if [[ -n "${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      identity:
        type: ${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}
EOF
    if [[ "${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}" == "UserAssigned" ]] && [[ ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER} -gt 0 ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
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
fi

if [[ -n "${AZURE_IDENTITY_TYPE_CONTROL_PLANE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      identity:
        type: ${AZURE_IDENTITY_TYPE_CONTROL_PLANE}
EOF
    if [[ "${AZURE_IDENTITY_TYPE_CONTROL_PLANE}" == "UserAssigned" ]] && [[ ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER} -gt 0 ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
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
fi

if [[ -n "${AZURE_IDENTITY_TYPE_COMPUTE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      identity:
        type: ${AZURE_IDENTITY_TYPE_COMPUTE}
EOF
    if [[ "${AZURE_IDENTITY_TYPE_COMPUTE}" == "UserAssigned" ]] && [[ ${AZURE_USER_ASSIGNED_IDENTITY_NUMBER} -gt 0 ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
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
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi

# when identity type is None, cluster sp only needs Contributor role
default_identity_type="UserAssigned"
master_identity_type="${default_identity_type}"
worker_identity_type="${default_identity_type}"
if [[ -n "${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}" ]]; then
    master_identity_type="${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}"
    worker_identity_type="${AZURE_IDENTITY_TYPE_DEFAULT_MACHINE}"
fi

if [[ -n "${AZURE_IDENTITY_TYPE_CONTROL_PLANE}" ]]; then
    master_identity_type="${AZURE_IDENTITY_TYPE_CONTROL_PLANE}"
fi

if [[ -n "${AZURE_IDENTITY_TYPE_COMPUTE}" ]]; then
    worker_identity_type="${AZURE_IDENTITY_TYPE_COMPUTE}"
fi

if [[ "${master_identity_type}" == "None" ]] && [[ "${worker_identity_type}" == "None" ]]; then
    if [[ -f "${CLUSTER_PROFILE_DIR}"/azure-sp-contributor.json ]]; then
        echo "Copy Azure credential azure-sp-contributor.json to SHARED_DIR"
        cp ${CLUSTER_PROFILE_DIR}/azure-sp-contributor.json ${SHARED_DIR}/azure-sp-contributor.json
    fi
fi
