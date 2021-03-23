#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
pip3 install --user yq
export PATH=~/.local/bin:$PATH

export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

REGION="${LEASED_RESOURCE}"

STACK_NAME=$(cat "${SHARED_DIR}/sharednetworkstackname")

vpc_id="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue')"
echo "Using vpc_id: ${vpc_id}"

cluster_domain=$(yq -r '.metadata.name + "." + .baseDomain' "${CONFIG}")
hosted_zone="$(aws route53 create-hosted-zone \
    --name "${cluster_domain}" \
    --vpc VPCRegion="${REGION}",VPCId="${vpc_id}" \
    --caller-reference "${cluster_domain}-$(date +"%Y-%m-%d-%H-%M-%S")" \
    --hosted-zone-config Comment="BYO hosted zone for ${cluster_domain}",PrivateZone=true |
  jq -r '.HostedZone.Id' | \
  sed -E 's|^/hostedzone/(.+)$|\1|' \
  )"
echo "Using hosted zone: ${hosted_zone}"

# save hostedzone name to ${SHARED_DIR} for deprovision step
echo "${hosted_zone}" >> "${SHARED_DIR}/byohostedzonename"

aws route53 change-tags-for-resource \
  --resource-type hostedzone \
  --resource-id "${hosted_zone}" \
  --add-tags "${TAGS}"

<"${CONFIG}" yq -y --arg zone "${hosted_zone}" '.platform.aws.hostedZone=$zone' > "${CONFIG}.patched"
mv "${CONFIG}.patched" "${CONFIG}"
