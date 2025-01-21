#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


CONFIG="${SHARED_DIR}/install-config.yaml"
vpcSubnetsFile="${SHARED_DIR}/customer_vpc_subnets.yaml"

cat "${vpcSubnetsFile}"
region="${LEASED_RESOURCE}"
declare -a zones=("${region}-1" "${region}-2" "${region}-3")
if [[ ${ZONES_COUNT} -eq 1 ]]; then
    zone=${zones[0]}
    echo "Adjusted zones to ${zone} based on ZONES_COUNT: ${ZONES_COUNT}."
    # temp_file=$(mktemp)
    # cp ${vpcSubnetsFile} ${temp_file}
    yq-go r "$vpcSubnetsFile" "platform.ibmcloud.controlPlaneSubnets" -j | jq --arg zone "$zone" '.[] | select(test($zone))' | yq-go w -i "$vpcSubnetsFile" 'platform.ibmcloud.controlPlaneSubnets' "$(cat)"
    yq-go r "$vpcSubnetsFile" "platform.ibmcloud.computeSubnets" -j | jq --arg zone "$zone" '.[] | select(test($zone))' | yq-go w -i "$vpcSubnetsFile" 'platform.ibmcloud.computeSubnets' "$(cat)"
    cat $vpcSubnetsFile
    yq-go m -x -i "${CONFIG}" "${vpcSubnetsFile}"
else
    yq-go m -x -i "${CONFIG}" "${vpcSubnetsFile}"
fi
echo "$CONFIG ======================"
cat ${CONFIG}
