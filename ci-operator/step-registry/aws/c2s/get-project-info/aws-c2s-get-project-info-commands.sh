#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION="${LEASED_RESOURCE}"

# reading shift_project_setting.json in cluster profile
#
# e.g.
# {
#   "us-iso-east-1": {
#     "source_region": "us-east-1",
#     "vpc_id": "vpc-02d3ec22d80ec499f",
#     "private_subnet": {
#       "id": "subnet-0132f5587ef134486",
#       "az": "us-iso-east-1c"
#     },
#     "public_subnet": {
#       "id": "subnet-072a0f8c475a84cca",
#       "az": "us-iso-east-1b"
#     },
#     "project_name": "OpenShift-QE-C2SEmu-CI2",
#     "vpc_stack_name": "OpenShift-QE-C2SEmu-CI2",
#     "machine_network": "10.143.0.0/16",
#     "temporary_credential_endpoint": "https://cap.digitalageexperts.com/api/v1/credentials",
#     "cross_account_role": "OpenShift-QE-C2SEmu-CI2-CAR2-CrossAccountRole-XCDV79IJ2XKQ",
#     "cert": "LS0t...",
#     "private_key": "LS0t..."
#   },
# }

shift_project_setting="${CLUSTER_PROFILE_DIR}/shift_project_setting.json"

vpc_id=$(jq -r ".\"${REGION}\".vpc_id" ${shift_project_setting})
machine_network=$(jq -r ".\"${REGION}\".machine_network" ${shift_project_setting})

# AllSubnetsIds=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[. as $o | keys[] | select(endswith("subnet")) | $o[.].id | split(",")[]]' | sed "s/\"/'/g")
PrivateSubnetIds=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[.private_subnet.id]' | sed "s/\"/'/g")
PublicSubnetIds=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[.public_subnet.id]' | sed "s/\"/'/g")
# AvailabilityZones=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[. as $o | keys[] | select(endswith("subnet")) | $o[.].az | split(",")[]]' | sed "s/\"/'/g")
PrivateAvailabilityZones=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[.private_subnet.az]' | sed "s/\"/'/g")
PublicAvailabilityZones=$(jq ".\"${REGION}\"" ${shift_project_setting} | jq -c '[.public_subnet.az]' | sed "s/\"/'/g")

echo "$vpc_id" > "${SHARED_DIR}/vpc_id"
echo "$machine_network" > "${SHARED_DIR}/machine_network"
echo "$PrivateSubnetIds" > "${SHARED_DIR}/private_subnet_ids"
echo "$PublicSubnetIds" > "${SHARED_DIR}/public_subnet_ids"
echo "$PrivateAvailabilityZones" > "${SHARED_DIR}/private_availability_zones"
echo "$PublicAvailabilityZones" > "${SHARED_DIR}/public_availability_zones"

# for C2S and SC2S, provide private zone and AZ only
echo "$PrivateSubnetIds" > "${SHARED_DIR}/subnet_ids"
echo "$PrivateAvailabilityZones" > "${SHARED_DIR}/availability_zones"

exit 0