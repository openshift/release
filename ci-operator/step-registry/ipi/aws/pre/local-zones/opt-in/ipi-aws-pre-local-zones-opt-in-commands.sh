#!/bin/bash

#
# Select random AWS Local Zone, opt-in the zone group (when opted-out),
# the save the zone name to be used in install-config.yaml.
#

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"

case ${EDGE_ZONE_TYPE} in
    "local-zone"|"wavelength-zone") echo "Selecting random zone with type: ${EDGE_ZONE_TYPE}" ;;
    *)
        echo "ERROR: invalid value for variable EDGE_ZONE_TYPE. Got: ${EDGE_ZONE_TYPE}, Allowed values: [local-zone | wavelength-zone]";
        exit 1 ;;
esac

zone_name=$(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones --filter Name=state,Values=available Name=zone-type,Values="${EDGE_ZONE_TYPE}" | jq -r '.AvailabilityZones[].ZoneName' | shuf | tail -n 1)
echo "Edge Zone selected: ${zone_name}"

zone_group_name=$(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones --filters Name=zone-name,Values="$zone_name" --query "AvailabilityZones[].GroupName" --output text)
echo "Zone Group discovered: ${zone_group_name}"

if [[ $(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
        --filters Name=zone-type,Values="${EDGE_ZONE_TYPE}" Name=zone-name,Values="$zone_name" \
        --query 'AvailabilityZones[].OptInStatus' --output text) == "opted-in" ]];
then
    echo "Zone group ${zone_group_name} already opted-in"
    echo -en "$zone_name" > "${SHARED_DIR}/edge-zone-name.txt"
    echo -en "$zone_group_name" > "${SHARED_DIR}/edge-zone-group-name.txt"
    exit 0
fi

aws --region "$REGION" ec2 modify-availability-zone-group --group-name "${zone_group_name}" --opt-in-status opted-in
echo "Zone group ${zone_group_name} opt-in status modified"

count=0
while true; do
    aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
        --filters Name=zone-type,Values="${EDGE_ZONE_TYPE}" Name=zone-name,Values="$zone_name" \
        | jq -r '.AvailabilityZones[]' |tee /tmp/az.stat
    if [[ "$(jq -r .OptInStatus /tmp/az.stat)" == "opted-in" ]]; then break; fi
    if [ $count -ge 10 ]; then
        echo "$(date --rfc-3339=seconds)> Timeout waiting for zone ${zone_name} attribute OptInStatus==opted-in"
        exit 1
    fi
    count=$((count+1))
    echo "$(date --rfc-3339=seconds)> Waiting OptInStatus with value opted-in [$count/10]"
    sleep 30
done

echo "Zone group ${zone_group_name} opted-in."
echo -en "$zone_name" > "${SHARED_DIR}/edge-zone-name.txt"
echo -en "$zone_group_name" > "${SHARED_DIR}/edge-zone-group-name.txt"