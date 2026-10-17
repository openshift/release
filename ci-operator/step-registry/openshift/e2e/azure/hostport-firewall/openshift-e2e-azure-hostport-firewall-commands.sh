#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Open the OTE host-port range on the cluster NSG (perfscale-azu-data-path-nsg pattern).
export AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az login --service-principal \
  -u "$(jq -r .clientId "${AZURE_AUTH_LOCATION}")" \
  -p "$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")" \
  --tenant "$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")" --output none
az account set --subscription "$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Infra ID: ${INFRA_ID}"

echo "Opening 30000-32767 on NSG ${INFRA_ID}-nsg"
az network nsg rule create -g "${INFRA_ID}-rg" --nsg-name "${INFRA_ID}-nsg" \
  --name ote-hostports --priority 106 --access Allow --direction Inbound \
  --protocol '*' --source-address-prefixes VirtualNetwork \
  --destination-port-ranges 30000-32767 --output none
