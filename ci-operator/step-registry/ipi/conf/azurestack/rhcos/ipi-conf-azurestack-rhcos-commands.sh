#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Set PATH to include YQ, installed via pip in the image
export PATH="$PATH:/usr/local/bin"

suffix_endpoint=$(cat "${SHARED_DIR}/SUFFIX_ENDPOINT")

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
source ${SHARED_DIR}/azurestack-login-script.sh

# Hard-coded storage account info for PPE3 environment.
# The resource group, storage account, & container are expected to exist.
resource_group=${RHCOS_VHD_RESOURCE_GROUP}
storage_account=${RHCOS_VHD_STORAGE_ACCOUNT}
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

PATCH="/tmp/install-config-clusterosimage.yaml.patch"
# create a patch with ClusterOSImage configuration
cat > "${PATCH}" << EOF
platform:
  azure:
    ClusterOSImage: ${vhd_blob_url}
EOF
# apply patch to install-config
yq-go m -x -i "${SHARED_DIR}/install-config.yaml" "${PATCH}"
