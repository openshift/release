#!/usr/bin/env bash

set -euo pipefail

function check_node_sse_with_cmk() {
    local node_name="$1"
    echo "Checking guest cluster node $node_name"

    np_name=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node "$node_name" -o jsonpath='{.metadata.labels.hypershift\.openshift\.io/nodePool}')
    if [[ -z "$np_name" ]]; then
        echo "Error: got empty NP name for node $node_name" >&2
        return 1
    fi

    des_id="$(oc get np -n clusters "$np_name" -o jsonpath='{.spec.platform.azure.diskEncryptionSetID}')"
    if [[ -z "$des_id" ]]; then
        echo "Error: got empty diskEncryptionSetID from NP $np_name" >&2
        return 1
    fi

    des_id_actual="$(az vm show --name "$node_name" -g "$hc_rg" --query 'storageProfile.osDisk.managedDisk.diskEncryptionSet.id' -o tsv)"
    if [[ "$des_id_actual" != "${des_id}" ]]; then
        echo "Error: expect disk encryption set $des_id but got $des_id_actual from VM"
        return 1
    fi
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Getting resource group from HostedCluster"
hc_rg=$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.resourceGroup}')
if [[ -z "$hc_rg" ]]; then
    echo "Error: got empty resource group from HostedCluster" >&2
    exit 1
fi

echo "Verifying osDisks on guest cluster nodes are encrypted with the same disk encryption set"
hc_nodes="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers | awk '{print $1}')"
for hc_node in $hc_nodes; do
    check_node_sse_with_cmk "$hc_node"
done
