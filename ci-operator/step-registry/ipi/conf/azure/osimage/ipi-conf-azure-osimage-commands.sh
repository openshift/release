#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
CONFIG="${SHARED_DIR}/install-config.yaml"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
KUBECONFIG="" oc registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

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

# create a patch to set osImage for compute
PATCH="/tmp/install-config-existingworkers-marketimage.yaml.patch"
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

if [[ ${ocp_minor_version} -ge 14 ]]; then
  if [[ "${OS_IMAGE_MASTERS}" != "" ]]; then
    image=${OS_IMAGE_MASTERS}
    IFS=':' read -ra imageInfo <<< "${image}"
    echo "imageInfo for master: " "${imageInfo[@]}"
    [[ "${OS_IMAGE_MASTERS_PLAN}" != "" ]] && masters_plan="plan: ${OS_IMAGE_MASTERS_PLAN}"
  fi

  # image plan is case-sensitive, make sure that publisher/offer/sku keep the same as plan 
  if [[ "${OS_IMAGE_MASTERS_PLAN}" == "WithPurchasePlan" ]] || [[ "${OS_IMAGE_MASTERS_PLAN}" == "" ]]; then
    imageInfo[0]=$(az vm image show --urn ${image} --query 'plan.publisher' -otsv)
    imageInfo[1]=$(az vm image show --urn ${image} --query 'plan.product' -otsv)
    imageInfo[2]=$(az vm image show --urn ${image} --query 'plan.name' -otsv)
  fi

  # create a patch to set osImage for control plane instances
  PATCH_MASTER="/tmp/install-config-master-marketimage.yaml.patch"
  cat > "${PATCH_MASTER}" << EOF
controlPlane:
  platform:
    azure:
      osImage:
        publisher: ${imageInfo[0]}
        offer: ${imageInfo[1]}
        sku: ${imageInfo[2]}
        version: ${imageInfo[3]}
        ${masters_plan}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH_MASTER}"
fi
