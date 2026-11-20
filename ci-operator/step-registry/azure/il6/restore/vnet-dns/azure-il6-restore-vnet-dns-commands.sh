#!/bin/bash

set -o nounset
set -o pipefail
# Deliberately NOT errexit: teardown is best-effort, and this step must not abort the rest of the
# post chain -- least of all the resource-group delete that follows it.

if [[ ! -f "${SHARED_DIR}/azure_il6_vnet_dns_override" ]]; then
    echo "VNet DNS servers were never repointed; nothing to restore."
    exit 0
fi

RG="${AZURE_IL6_RESOURCE_GROUP}"

# Commercial plane only, with the azure-qe principal: the VNet is a commercial-plane resource.
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az cloud set --name AzureCloud
az login --service-principal \
    -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
    -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
    --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

echo "--- restoring VNet DNS servers to the emulator's (${AZURE_IL6_EMULATOR_DNS})"

# Retried, because this is the one teardown action whose failure is visible to the NEXT run rather
# than to this one. A single transient ARM error here would hand the next job a VNet that resolves
# nothing.
restored="no"
for attempt in 1 2 3; do
    # shellcheck disable=SC2086 -- AZURE_IL6_EMULATOR_DNS is a space-separated list of servers.
    if az network vnet update -g "${RG}" -n "${AZURE_IL6_VNET_NAME}" \
        --dns-servers ${AZURE_IL6_EMULATOR_DNS} -o none; then
        restored="yes"
        break
    fi
    echo "    attempt ${attempt} failed; retrying in $((attempt * 10))s"
    sleep $((attempt * 10))
done

if [[ "${restored}" == "yes" ]]; then
    echo "OK: dnsServers restored before the bastion is removed."
    exit 0
fi

echo "WARNING: could not restore dnsServers after 3 attempts. The VNet will point at a bastion"
echo "         this teardown is about to delete. azure-il6-check-prereqs detects and repairs that"
echo "         at the start of the next run, and the fixture lease keeps another run from starting"
echo "         in the meantime -- so this is recoverable, but it should be investigated if it"
echo "         recurs."
