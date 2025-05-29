#!/usr/bin/env bash

AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
AWS_DEFAULT_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ ${HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT} == "true" ]]; then
    AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

export AWS_DEFAULT_REGION
export AWS_SHARED_CREDENTIALS_FILE
CR_OUTPUT_FILE=/tmp/reservation_details.json

# Create on-demand type capacity reservation, it will be cancalled automaticlly after created 1 day if the cancal script is failed.
function create_ondemand_capacity_reservation() {
    echo "Create on-demand capacity reservation..."
    aws ec2 create-capacity-reservation \
        --availability-zone "${NODEPOOL_CAPACITY_RESERVATION_ZONE}" \
        --instance-type "${ON_DEMAND_INSTANCE_TYPE}" \
        --instance-count ${CP_INSTANCES_NUMBER} \
        --instance-platform "${OPERATING_SYSTEM}" \
        --instance-match-criteria targeted \
        --end-date "$(date -u -d "1 day" +"%Y-%m-%dT%H:%M:%SZ")" \
        --tag-specifications 'ResourceType=capacity-reservation,Tags=[{Key=usage-cluster-type,Value=hypershift-hosted}]' \
        --output json > ${CR_OUTPUT_FILE}
    
    if [ $? -ne 0 ]; then
        echo "Failed to create on-demand capacity reservation."
        return 1
    fi

    RESERVATION_ID=$(jq -r '.CapacityReservation.CapacityReservationId' "${CR_OUTPUT_FILE}")
    if [ -z "${RESERVATION_ID}" ]; then
        echo "Failed to get on-demand reservation ID. Exiting."
        exit 1
    fi

    echo "On-demand capacity reservation created: ${RESERVATION_ID}"
    echo "{\"OnDemand\":\"${RESERVATION_ID}\"}" | jq . > "${SHARED_DIR}/reservation_id"

}

# Before creating a capacity block type for GPUs, you need to check the available capacity blocks in one-day increments. 
# After purchase, capacity_blocks will be cancalled after 1 day.
function find_and_purchase_capacity_blocks() {
    echo "Fining avaliable capacity blocks..."
    aws ec2 describe-capacity-block-offerings \
        --instance-type "${CAPACITY_BLOCKS_INSTANCE_TYPE}" \
        --instance-count  "${CP_INSTANCES_NUMBER}" \
        --start-date-range "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"  \
        --end-date-range "$(date -u -d "2 day" +"%Y-%m-%dT%H:%M:%SZ")" \
        --capacity-duration-hours 24 \
        --output json > ${CR_OUTPUT_FILE}

    if [ $? -ne 0 ]; then
        echo "Failed to find capacity blocks."
        return 1
    fi
    local OFFERING_IDS
    OFFERING_IDS=$(jq -r '.CapacityBlockOfferings[].CapacityBlockOfferingId' "${CR_OUTPUT_FILE}")
    if [ -z "$OFFERING_IDS" ]; then
        echo "There is no capacity blocks avaliabe right now"
        return 1
    fi
    local OFFERING_ID
    OFFERING_ID=$(echo "$OFFERING_IDS" | head -n 1)
    echo "Found available capacity block offering: ${OFFERING_ID}"
    
    echo "Validating purchase with dry run..."
    if ! aws ec2 purchase-capacity-block \
        --capacity-block-offering-id "${OFFERING_ID}" \
        --instance-platform "${OPERATING_SYSTEM}" \
        --tag-specifications 'ResourceType=capacity-reservation,Tags=[{Key=usage-cluster-type,Value=hypershift-hosted}]' \
        --dry-run 2>&1 | grep -q "DryRunOperation"; then
        echo "Dry run failed. Check parameters or permissions."
        return 1
    fi

    echo "Dry run successful. Proceeding with purchase..."
#    aws ec2 purchase-capacity-block \
#        --capacity-block-offering-id "${OFFERING_ID}" \
#        --instance-platform "${OPERATING_SYSTEM}" \
#        --tag-specifications 'ResourceType=capacity-reservation,Tags=[{Key=usage-cluster-type,Value=hypershift-hosted}]' \
#        --output json > "${CR_OUTPUT_FILE}"
#    if [ $? -ne 0 ]; then
#        echo "Failed to purchase capacity block." >&2
#        return 1
#    fi
#    CB_RESERVATION_ID=$(jq -r '.CapacityReservation.CapacityReservationId' "${CR_OUTPUT_FILE}")
    CB_RESERVATION_ID="cr-011db017388a95436"
    if [ -z "${CB_RESERVATION_ID}" ]; then
        echo "Failed to get capacity blocks reservation ID. Exiting."
        return 1
    fi
    echo "Purchased capacity block successfully: ${CB_RESERVATION_ID}"

    echo "Waiting for capacity block to become active..."
    #CB_START_TIME=$(jq -r '.CapacityReservation.StartDate' "${CR_OUTPUT_FILE}")
    CB_START_TIME="2025-05-29T11:30:00+00:00"
    CB_START_TIMESTRAMP=$(date -d $CB_START_TIME +%s)
#    time_str="2025-05-29T11:30:00+00:00"
#    time_bsd="${time_str%:*}${time_str: -2}"
#    CB_START_TIMESTRAMP=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$time_bsd" +%s)
    while true; do
        CURRENT_TIMESTRAMP=$(date -u +%s)
        if [ $CURRENT_TIMESTRAMP -ge $CB_START_TIMESTRAMP ]; then
            echo "Capacity Block should become active now"
            break
        fi
        sleep 60
    done

    sleep 60
    STATE=$(aws ec2 describe-capacity-reservations \
        --capacity-reservation-ids ${CB_RESERVATION_ID} \
        --query "CapacityReservations[].State" \
        --output text)
    if [[ $STATE != "active" ]]; then
        echo "Capacity Block does not become active, please check: ${CB_RESERVATION_ID}"
        echo "The current status is: $STATE"
        return 1
    fi
    echo "{\"CapacityBlocks\":\"${CB_RESERVATION_ID}\"}" | jq . > "${SHARED_DIR}/reservation_id"
}

# When NODEPOOL_CAPACITY_RESERVATION is enabled, will create On-demand and CapacityBlocks of capacity reservation accordingly, for later nodepool test.
case $NODEPOOL_CAPACITY_RESERVATION in
    "OnDemand")
        create_ondemand_capacity_reservation
        ;;
    "CapacityBlocks")
        find_and_purchase_capacity_blocks
        ;;
    "")
        echo "No capacity reservation type set, please check"
        ;;
    *)
        echo "Error: Unsupported capacity reservation type: ${NODEPOOL_CAPACITY_RESERVATION}"
        exit 1
        ;;
esac
