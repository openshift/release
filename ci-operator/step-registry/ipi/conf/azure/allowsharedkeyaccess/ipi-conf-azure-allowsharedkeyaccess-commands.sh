#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

# Set allowSharedKeyAccess
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-allowsharedkeyaccess.yaml.patch"

if [[ -z "${AZURE_ALLOW_SHARED_KEY_ACCESS}" ]]; then
    echo "ENV AZURE_ALLOW_SHARED_KEY_ACCESS is empty, skip this step!"
    exit 0
fi
cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    allowSharedKeyAccess: ${AZURE_ALLOW_SHARED_KEY_ACCESS}
EOF
# require a new permission "Storage Blob Data Contributor"
if [[ "${AZURE_ALLOW_SHARED_KEY_ACCESS}" == "false" ]]; then
    AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
    if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
        AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
    elif [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
        AZURE_AUTH_LOCATION=${SHARED_DIR}/azure-sp-contributor.json
    fi

    AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
    AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
    AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
    AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

    # log in with az
    if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
        az cloud set --name AzureUSGovernment
    else
        az cloud set --name AzureCloud
    fi
    az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
    az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

    if [[ -f "${SHARED_DIR}/azure_managed_identity_osServicePrincipal.json" ]]; then
        echo "Install with managed identity auth, set clientId to managed identity id"
        AZURE_AUTH_CLIENT_ID="$(<${SHARED_DIR}/azure_managed_identity_osServicePrincipal.json jq -r .clientId)"
    fi

    echo "allowSharedKeyAccess is set to false, installer SP requires 'Storage Blob Data Contributor', assign this role to SP ${AZURE_AUTH_CLIENT_ID}"
    az role assignment create --assignee ${AZURE_AUTH_CLIENT_ID} --role "Storage Blob Data Contributor" --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}      
    # for delete
    az role assignment list --assignee ${AZURE_AUTH_CLIENT_ID} --role "Storage Blob Data Contributor" --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID} --query '[].id' -otsv >> "${SHARED_DIR}"/azure_role_assignment_ids
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi
