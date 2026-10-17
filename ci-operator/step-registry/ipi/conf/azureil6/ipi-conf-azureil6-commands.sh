#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

SP_FILE="/var/run/azureil6-secrets/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
    echo "ERROR: IL6 service principal not found at ${SP_FILE}."
    echo
    echo "It is delivered by the Vault credential collection 'installer-ci-azureil6',"
    echo "group 'service-principal'. The collection must contain a key named"
    echo "'osServicePrincipal.json' holding a JSON object with clientId, clientSecret,"
    echo "tenantId and subscriptionId for the EMULATED IL6 plane -- not the azure-qe"
    echo "service principal, which is a commercial-plane credential."
    exit 1
fi

for field in clientId clientSecret tenantId subscriptionId; do
    if [[ -z "$(jq -r --arg f "${field}" '.[$f] // empty' "${SP_FILE}")" ]]; then
        echo "ERROR: ${SP_FILE} is missing required field '${field}'."
        exit 1
    fi
done

# ipi-install-install-in-bastion scps this to the bastion and points AZURE_AUTH_LOCATION at it,
# so that openshift-install authenticates against the IL6 plane rather than against the
# commercial-plane azure-qe principal that the cluster profile supplies.
cp "${SP_FILE}" "${SHARED_DIR}/azure_il6_osServicePrincipal.json"

# ---------------------------------------------------------------- install-config
PATCH="${SHARED_DIR}/azureil6-install-config.yaml.patch"
cat > "${PATCH}" << EOF
platform:
  azure:
    cloudName: ${AZURE_IL6_CLOUD_NAME}
    armEndpoint: ${AZURE_IL6_ARM_ENDPOINT}
    region: ${AZURE_IL6_CLUSTER_REGION}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
rm -f "${PATCH}"

# ---------------------------------------------------------------- safety assertion
#
# Three separate code paths in this registry run the equivalent of 'az group delete -y' on
# whatever group they are pointed at:
#
#   openshift-install destroy           deletes platform.azure.resourceGroupName, unconditionally
#   azure-deprovision-resourcegroup     deletes every group named in ${SHARED_DIR}/resourcegroup*
#   ipi-deprovision-azure-resourcegroup deletes platform.azure.resourceGroupName
#
# The shared emulator group must therefore only ever appear as networkResourceGroupName. Fail
# loudly here rather than discovering the mistake when the environment is gone.
cluster_rg="$(yq-go r "${CONFIG}" 'platform.azure.resourceGroupName')"
if [[ -n "${cluster_rg}" && "${cluster_rg}" != "null" ]]; then
    if [[ "${cluster_rg}" == "${AZURE_IL6_RESOURCE_GROUP}" ]]; then
        echo "ERROR: platform.azure.resourceGroupName is set to '${cluster_rg}', which is the"
        echo "shared emulator resource group. 'openshift-install destroy' would delete it,"
        echo "taking the VNet, VPN gateway and both IPsec tunnels with it."
        echo
        echo "The shared group belongs in platform.azure.networkResourceGroupName only."
        exit 1
    fi
    echo "NOTE: platform.azure.resourceGroupName is '${cluster_rg}' (not the shared group)."
fi

network_rg="$(yq-go r "${CONFIG}" 'platform.azure.networkResourceGroupName')"
if [[ "${network_rg}" != "${AZURE_IL6_RESOURCE_GROUP}" ]]; then
    echo "ERROR: platform.azure.networkResourceGroupName is '${network_rg}', expected"
    echo "'${AZURE_IL6_RESOURCE_GROUP}'. Did azure-il6-provision-subnets run before this step?"
    exit 1
fi

for key in resourcegroup resourcegroup_cluster resourcegroup_vnet resourcegroup_nsg resourcegroup_sa resourcegroup_aks; do
    if [[ -f "${SHARED_DIR}/${key}" ]] && grep -qx "${AZURE_IL6_RESOURCE_GROUP}" "${SHARED_DIR}/${key}"; then
        echo "ERROR: \${SHARED_DIR}/${key} names the shared emulator resource group."
        echo "azure-deprovision-resourcegroup deletes every group listed in those files."
        exit 1
    fi
done

# ---------------------------------------------------------------- az login script
#
# NOTE the QUOTED heredoc. With an unquoted '<< EOF' the shell expands $AAD_CLIENT_SECRET here, at
# write time, leaving the service principal secret in plaintext inside ${SHARED_DIR} -- which then
# gets copied to the bastion and is one careless 'cp' away from a public artifact bucket. Quoting
# the delimiter writes the variable names literally; they are expanded on the bastion, at run
# time, from an environment that is never captured in logs.
LOGIN_SCRIPT="${SHARED_DIR}/azureil6-login-script.sh"
cat > "${LOGIN_SCRIPT}" << 'EOF'
#!/bin/bash
# Configure the az CLI for the emulated Azure IL6 plane.
# Expects in the environment: APP_ID, AAD_CLIENT_SECRET, TENANT_ID, SUBSCRIPTION_ID

if [[ -f /opt/azureil6/ca-bundle.pem ]]; then
    export REQUESTS_CA_BUNDLE=/opt/azureil6/ca-bundle.pem
    export SSL_CERT_FILE=/opt/azureil6/ca-bundle.pem
fi
EOF

# Static, non-secret values are interpolated separately so the secret-bearing lines above stay
# inside a quoted heredoc.
cat >> "${LOGIN_SCRIPT}" << EOF

az cloud register -n ${AZURE_IL6_CLOUD_REGISTER_NAME} \\
    --endpoint-resource-manager "${AZURE_IL6_ARM_ENDPOINT}" 2>/dev/null \\
  || az cloud update -n ${AZURE_IL6_CLOUD_REGISTER_NAME} \\
    --endpoint-resource-manager "${AZURE_IL6_ARM_ENDPOINT}"
az cloud set -n ${AZURE_IL6_CLOUD_REGISTER_NAME}
az configure --defaults location=${AZURE_IL6_CLUSTER_REGION}
EOF

# Deliberately NOT present, unlike ipi-conf-azurestack:
#     az cloud update --profile 2019-03-01-hybrid
# Azure Stack Hub needs that API profile downgrade. IL6 runs current API versions and the
# downgrade is explicitly disallowed.

cat >> "${LOGIN_SCRIPT}" << 'EOF'
az login --service-principal -u "${APP_ID}" -p "${AAD_CLIENT_SECRET}" --tenant "${TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"
EOF

chmod +x "${LOGIN_SCRIPT}"

echo "----- generated ${LOGIN_SCRIPT} -----"
cat "${LOGIN_SCRIPT}"

echo "----- install-config.yaml platform.azure -----"
yq-go r "${CONFIG}" 'platform.azure'
