#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

# The azure-qe cluster profile's own principal. A dedicated IL6 principal was assumed to be
# necessary, but azure-il6-az-check demonstrated this one authenticating against the emulated
# ARM endpoint and enumerating it, so the extra Vault group is dead weight.
SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
    echo "ERROR: service principal not found at ${SP_FILE}."
    echo
    echo "It comes from the azure-qe cluster profile, which every test in this chain already"
    echo "mounts. If it is missing, the cluster_profile is wrong or the profile's secret has"
    echo "lost its osServicePrincipal.json key."
    exit 1
fi

for field in clientId clientSecret tenantId subscriptionId; do
    if [[ -z "$(jq -r --arg f "${field}" '.[$f] // empty' "${SP_FILE}")" ]]; then
        echo "ERROR: ${SP_FILE} is missing required field '${field}'."
        exit 1
    fi
done

# ipi-install-install-in-bastion scps this to the bastion and points AZURE_AUTH_LOCATION at it.
# It is the azure-qe principal: the emulator fronts the same subscription, so the same credential
# authenticates on both planes. Copied under an IL6-specific name anyway, so that if the emulator
# ever does need its own principal, only this one line has to change.
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
# No az login script is generated here. An earlier revision produced
# ${SHARED_DIR}/azureil6-login-script.sh, but nothing ever sourced it, and it could not have
# worked if anything had: no step exports APP_ID, AAD_CLIENT_SECRET, TENANT_ID or
# SUBSCRIPTION_ID into the environment it expected. azure-il6-bastion-setup and
# azure-il6-az-check configure and drive az on the bastion directly.

echo "----- install-config.yaml platform.azure -----"
yq-go r "${CONFIG}" 'platform.azure'
