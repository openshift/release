#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Checking NodePool specs"
desId="$(oc get np -A -o jsonpath='{.items[0].spec.platform.azure.diskEncryptionSetID}')"
if [[ -z "$desId" ]]; then
    echo "Error: got empty diskEncryptionSetID from NodePool" >&2
    exit 1
fi

echo "Getting resource group from HostedCluster"
hc_rg=$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.resourceGroup}')
if [[ -z "$hc_rg" ]]; then
    echo "Error: got empty resource group from HostedCluster" >&2
    exit 1
fi

echo "Verifying osDisks on guest cluster nodes are encrypted with the same disk encryption set"
hc_nodes="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers | awk '{print $1}')"
for hc_node in ${hc_nodes}; do
    echo "Checking guest cluster node $hc_node"
    hc_node_des_id="$(az vm show --name "${hc_node}" -g "${hc_rg}" --query 'storageProfile.osDisk.managedDisk.diskEncryptionSet.id' -otsv)"
    if [[ "${hc_node_des_id}" != "${desId}" ]]; then
        echo "Error: expect disk encryption set $desId but got $hc_node_des_id from VM"
    fi
    echo "Guest cluster node $hc_node correctly encrypted"
done
