#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


CONFIG="${SHARED_DIR}/install-config.yaml"
vpcSubnetsFile="${SHARED_DIR}/customer_vpc_subnets.yaml"

cat "${vpcSubnetsFile}"
region="${LEASED_RESOURCE}"
declare -a zones=("${region}-1" "${region}-2" "${region}-3")
if (( zones_COUNT -lt 3 )); then
    zones=("${zones[@]:0:zones_COUNT}")
    echo "Adjusted zones to ${#zones[@]} based on zones_COUNT: ${zones_COUNT}."
#     readarray -t control_plane_subnets < <(yq-go r -j ${vpcSubnetsFile}  'platform.ibmcloud.controlPlaneSubnets(test)')
#     echo ${control_plane_subnets[@]}
# yq-go r ${vpcSubnetsFile} '.platform.ibmcloud.controlPlaneSubnets |= map(select(test("'"${zones[0]}""))) |
# .platform.ibmcloud.computeSubnets |= map(select(test("'"${zones[0]}"")))
# ' ${vpcSubnetsFile} > "$output_file"

#     control_plane_subnets=($(yq-go e '.controlPlaneSubnets[]' "$vpcSubnetsFile"))
#     compute_subnets=($(yq-go e '.computeSubnets[]' "$vpcSubnetsFile"))
#     yq-go e "
# .controlPlaneSubnets |= map(select(test(\"^.*${zone}.*$\"))) |
# .computeSubnets |= map(select(test(\"^.*${zone}.*$\")))
# " "$vpcSubnetsFile" > "$vpcSubnetsFile"
fi

yq-go m -x -i "${CONFIG}" "${vpcSubnetsFile}"


sleep 2h