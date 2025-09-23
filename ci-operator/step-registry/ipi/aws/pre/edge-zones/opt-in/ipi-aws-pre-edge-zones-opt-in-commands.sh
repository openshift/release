#!/bin/bash

#
# Select one random AWS Local Zone and Wavelength Zone each, opted into the
# zone group (when opted-out), saving the zone name to be used in network
# provisioning and install-config.yaml.
#

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"
echo "declare -A edge_zone_groups" > "${SHARED_DIR}/edge-zone-groups.env"

# Print a message with timestamp
function echo_date() {
    echo "$(date --rfc-3339=seconds)> $*"
}

function select_and_opt_in_zone() {
    local zone_type=$1
    local zone_name
    local zone_group_name

    # Randomly select the zone
    zone_name=$(aws --region "$REGION" ec2 describe-availability-zones \
        --all-availability-zones \
        --filter Name=state,Values=available Name=zone-type,Values="${zone_type}" \
        | jq -r '.AvailabilityZones[].ZoneName' | shuf | tail -n 1)
    echo_date "Edge Zone selected: ${zone_name}"

    zone_group_name=$(aws --region "$REGION" ec2 describe-availability-zones \
        --all-availability-zones \
        --filters Name=zone-name,Values="$zone_name" \
        --query "AvailabilityZones[].GroupName" --output text)
    echo_date "Zone Group discovered: ${zone_group_name}"

    if [[ $(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
            --filters Name=zone-type,Values="${zone_type}" Name=zone-name,Values="$zone_name" \
            --query 'AvailabilityZones[].OptInStatus' --output text) == "opted-in" ]];
    then
        echo_date "Zone group ${zone_group_name} already opted-in"
        echo "$zone_name" >> "${SHARED_DIR}/edge-zone-names.txt"
        echo "edge_zone_groups[$zone_name]=\"$zone_group_name\"" >> "${SHARED_DIR}/edge-zone-groups.env"
        return
    fi

    aws --region "$REGION" ec2 modify-availability-zone-group --group-name "${zone_group_name}" --opt-in-status opted-in
    echo_date "Zone group ${zone_group_name} opt-in status modified"

    count=0
    while true; do
        aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
            --filters Name=zone-type,Values="${zone_type}" Name=zone-name,Values="$zone_name" \
            | jq -r '.AvailabilityZones[]' |tee /tmp/az.stat
        
        if [[ "$(jq -r .OptInStatus /tmp/az.stat)" == "opted-in" ]]; then break; fi

        if [ $count -ge 10 ]; then
            echo_date "Timeout waiting for zone ${zone_name} attribute OptInStatus==opted-in"
            exit 1
        fi

        count=$((count+1))
        echo_date "Waiting OptInStatus with value opted-in [$count/10]"
        sleep 30
    done

    echo_date "Zone group ${zone_group_name} opted-in."
    echo_date "Saving zone name ${zone_name}"
    echo "$zone_name" >> "${SHARED_DIR}/edge-zone-names.txt"
    echo "edge_zone_groups[$zone_name]=\"$zone_group_name\"" >> "${SHARED_DIR}/edge-zone-groups.env"
}


function select_option() {
    local zone_type=${1}
    case ${zone_type} in
        "local-zone"|"wavelength-zone")
            echo "Selecting random zone with type: ${zone_type}";
            select_and_opt_in_zone "${zone_type}";
            ;;
        *)
            echo "ERROR: invalid value for variable EDGE_ZONE_TYPES. Got: ${zone_type}, Allowed values: [local-zone | wavelength-zone]";
            exit 1 ;;
    esac
}


if [[ "${EDGE_ZONES_LIST}" != "" ]]; then
    for z_name in $(echo ${EDGE_ZONES_LIST} | sed 's/,/\n/g');
    do
        echo "EDGE_ZONES_LIST is set: ${EDGE_ZONES_LIST}"
        echo "$z_name" >> "${SHARED_DIR}/edge-zone-names.txt"
        aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones --filters Name=zone-name,Values="$z_name" | tee /tmp/az.stat
        z_group_name=$(jq -r '.AvailabilityZones[].GroupName' /tmp/az.stat)
        z_opted_in_status=$(jq -r '.AvailabilityZones[].OptInStatus' /tmp/az.stat)
        if [[ "${z_group_name}" == "" ]]; then
            echo "Error: ${z_name} is not valid, exit now."
            return 1
        fi

        if [[ "${z_opted_in_status}" != "opted-in" ]]; then
            echo "Error: ${z_name} is not in \"opted-in\" status, exit now."
            return 1
        fi
        echo "edge_zone_groups[$z_name]=\"$z_group_name\"" >> "${SHARED_DIR}/edge-zone-groups.env"
    done
else
    for ZTYPE in $(echo ${EDGE_ZONE_TYPES-}  | tr ',' '\n');
    do
        select_option "$ZTYPE";
    done
fi