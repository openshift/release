#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Set PATH to include YQ, installed via pip in the image
export PATH="$PATH:/usr/local/bin"

tenant_id=$(jq -r .tenantId "${SHARED_DIR}/osServicePrincipal.json")
aad_client_secret=$(jq -r .clientSecret "${SHARED_DIR}/osServicePrincipal.json")
app_id=$(jq -r .clientId "${SHARED_DIR}/osServicePrincipal.json")


azurestack_endpoint=$(cat "${SHARED_DIR}/AZURESTACK_ENDPOINT")
suffix_endpoint=$(cat "${SHARED_DIR}/SUFFIX_ENDPOINT")

az cloud register \
    -n PPE \
    --endpoint-resource-manager "${azurestack_endpoint}" \
    --suffix-storage-endpoint "${suffix_endpoint}" 
az cloud set -n PPE
az cloud update --profile 2019-03-01-hybrid
az login --service-principal -u "$app_id" -p "$aad_client_secret" --tenant "$tenant_id" > /dev/null

# Hard-coded storage account info for PPE3 environment.
# The resource group, storage account, & container are expected to exist.
resource_group=rhcos-storage-rg
storage_account=rhcosvhdsa
account_key=$(az storage account keys list -g $resource_group --account-name $storage_account --query "[0].value" -o tsv)
container=vhd

compressed_vhd_url=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.azurestack.formats."vhd.gz".disk.location')
vhd_fn=$(basename "$compressed_vhd_url" .gz)

exists=$(az storage blob exists --container-name "$container" --name "$vhd_fn" --account-name "$storage_account" --account-key "$account_key" --query "exists")
if [ "$exists" == "false" ]; then
    compressed_vhd_fn=$(basename "$compressed_vhd_url")
    curl -L "$compressed_vhd_url" -o "/tmp/$compressed_vhd_fn"
    gunzip "/tmp/$compressed_vhd_fn"

    az storage blob upload --account-name "$storage_account" --account-key "$account_key" -c "$container" -n "$vhd_fn" -f "/tmp/$vhd_fn"
fi

vhd_blob_url="https://$storage_account.blob.$suffix_endpoint/$container/$vhd_fn"

# shellcheck disable=SC2016
yq --arg url "${vhd_blob_url}" -i -y '.platform.azure.ClusterOSImage=$url' "${SHARED_DIR}/install-config.yaml"
