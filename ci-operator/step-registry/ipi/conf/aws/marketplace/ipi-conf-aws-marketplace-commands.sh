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


# All available images on AWS Marketplace
aws --region $REGION ec2 describe-images --owners aws-marketplace \
  --filters "Name=product-code.type,Values=marketplace" "Name=product-code,Values=${product_code}" > $aws_marketplace_images


# Select proper version.

# Get readable version from image, e.g. 4.8.49, 4.12.0-0.nightly-2022-09-05-090751
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

oc registry login
version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} -ojson | jq -r '.metadata.version')
image_name_prefix="rhcos-`echo ${version} | awk -F '.' '{print $1$2}'`" # e.g. rhcos-48, rhcos-412

jq --arg v "$image_name_prefix" '.Images[] | select(.Name | startswith($v))' "$aws_marketplace_images" | jq -s | jq -r '. | sort_by(.Name) | last' > $selected_image
image_id=$(jq -r '.ImageId' $selected_image)

if [[ "$image_id" == "" ]] || [[ "$image_id" == "null" ]]; then
  # While in the new version development phase, generally, the AWS Marketplace image for this version is not available, so we choose the latest one instead
  echo "WARN: No image is available that matches the current version, choosing the latest image ... "
  jq '.Images[]' "$aws_marketplace_images" | jq -s | jq -r '. | sort_by(.Name | sub("^rhcos-"; "") | split(".")[0] | tonumber) | last' > $selected_image
  image_id=$(jq -r '.ImageId' $selected_image)
fi

if [[ "$image_id" == "" ]] || [[ "$image_id" == "null" ]]; then
  echo "ERROR: Can not find images on AWS Marketplace, region: $REGION, product code: $product_code, exit now"
  exit 1
fi

IMAGE_ID_PATCH="${ARTIFACT_DIR}/install-config-marketplace-image-id.yaml.patch"
image_name=$(jq -r '.Name' $selected_image)
echo "Using AWS Marketplace image ${image_name} for compute nodes, image id: ${image_id}"

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
