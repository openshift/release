#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="${LEASED_RESOURCE}"


product_code="5bn121hij41332ueh3nn53tc5" # OCP

aws_marketplace_images="${ARTIFACT_DIR}/aws_marketplace_images.json"
selected_image="${ARTIFACT_DIR}/selected_image.json"

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

# All available images on AWS Marketplace
aws --region $REGION ec2 describe-images --owners aws-marketplace \
  --filters "Name=product-code.type,Values=marketplace" "Name=product-code,Values=${product_code}" > $aws_marketplace_images


# Select proper version.
# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# RELEASE_IMAGE_LATEST_FROM_BUILD_FARM is pointed to the same image as RELEASE_IMAGE_LATEST, 
# but for some ci jobs triggerred by remote api, RELEASE_IMAGE_LATEST might be overridden with 
# user specified image pullspec, to avoid auth error when accessing it, always use build farm 
# registry pullspec.
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
    tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
    echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
    tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
    echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
    TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
    TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

dir=$(mktemp -d)
pushd "${dir}"
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret
version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} -ojson | jq -r '.metadata.version')
echo "get ocp version: ${version}"
rm pull-secret
popd

ocp_major_version=$( echo "${version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${version}" | awk --field-separator=. '{print $2}' )

v=$ocp_minor_version
image_id=""

# from current version to 4.11 select the latest compatible image
#
# e.g.for the image list
# "rhcos-413.92.202305021736-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845"
# "rhcos-411.86.202207150124-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845"
# "rhcos-x86_64-415.92.202402201450-0-59ead7de-2540-4653-a8b0-fa7926d5c845"
# "rhcos-412.86.202212081411-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845"
# 
# 4.11 -> rhcos-411.86.202207150124-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845
# 4.13 -> rhcos-413.92.202305021736-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845
# 4.14 -> rhcos-413.92.202305021736-0-x86_64-Marketplace-59ead7de-2540-4653-a8b0-fa7926d5c845
# 4.15 -> rhcos-x86_64-415.92.202402201450-0-59ead7de-2540-4653-a8b0-fa7926d5c845
# 4.16 -> rhcos-x86_64-415.92.202402201450-0-59ead7de-2540-4653-a8b0-fa7926d5c845
#

while [ $v -gt 10 ]
do
  v_xy="${ocp_major_version}${v}"
  echo "Checking ${v_xy} ..."
  jq --arg r "^rhcos-(x86_64-){0,1}${v_xy}\..*" '.Images[] | select(.Name | test($r))' "$aws_marketplace_images" | jq -s | jq -r '. | sort_by(.Name | sub("^rhcos-x86_64-"; "") | sub("^rhcos-"; "")) | last' > $selected_image
  image_id=$(jq -r '.ImageId' $selected_image)

  if ! is_empty "$image_id"; then
    image_name=$(jq -r '.Name' $selected_image)
    image_location=$(jq -r '.ImageLocation' $selected_image)
    echo "Using AWS Marketplace image ${image_name} for compute nodes, image id: ${image_id}, location: ${image_location}"
    break
  fi
  v=$((v-1))
done

if is_empty "$image_id"; then
  echo "ERROR: Can not find images on AWS Marketplace, region: $REGION, product code: $product_code, exit now"
  exit 1
fi

IMAGE_ID_PATCH="${ARTIFACT_DIR}/install-config-marketplace-image-id.yaml.patch"

cat > "${IMAGE_ID_PATCH}" << EOF
compute:
- platform:
    aws:
      amiID: ${image_id}      
EOF
yq-go m -x -i "${CONFIG}" "${IMAGE_ID_PATCH}"


# Instance type
if [[ ${USE_MARKETPLACE_CONTRACT_NODE_TYPE_ONLY} == "yes" ]]; then
  NODE_TYPE_PATCH="${ARTIFACT_DIR}/install-config-marketplace-instance-type.yaml.patch"
  node_type="m5.2xlarge"
  echo "Replace instance type with $node_type which presents in the contract."
  

  cat > "${NODE_TYPE_PATCH}" << EOF
compute:
- platform:
    aws:
      type: ${node_type}
EOF
  yq-go m -x -i "${CONFIG}" "${NODE_TYPE_PATCH}"
fi
