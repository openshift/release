#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-existingworkers-marketimage.yaml.patch"

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
# random select the market-place image
offer="rh-ocp-worker"
images=$(az vm image list --all --offer ${offer} --publisher redhat -o tsv --query "[?starts_with(urn,'RedHat:${offer}:${offer}')].urn")
mapfile -t marketImages <<< "${images}"
echo "choice market-place image from:" "${marketImages[@]}"
imageTotal=${#marketImages[@]}
echo "Image total: ${imageTotal} "
if [ ${imageTotal} -lt 1 ] ; then
  echo "Fail to find the market-place image under the ${AZURE_AUTH_LOCATION}"
  exit 1
fi
selected_image_idx=$((RANDOM % ${imageTotal}))
image=${marketImages[selected_image_idx]}
echo "$(date -u --rfc-3339=seconds) - Selected image ${image}"
IFS=':' read -ra imageInfo <<< "${image}"
echo "imageInfo: " "${imageInfo[@]}"
# create a patch with existing resource group configuration
cat > "${PATCH}" << EOF
compute:
- platform:
    azure:
      osImage:
        publisher: redhat
        offer: ${imageInfo[1]}
        sku: ${imageInfo[2]}
        version: ${imageInfo[3]}
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
