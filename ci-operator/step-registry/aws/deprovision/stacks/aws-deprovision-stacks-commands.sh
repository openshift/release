#!/bin/bash

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION=${REGION:-$LEASED_RESOURCE}

# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi


function delete_enis()
{
    local filter_key=$1 filter_value=$2
    local eni_ids
    eni_ids=$(aws --region "$REGION" ec2 describe-network-interfaces \
        --filters "Name=${filter_key},Values=${filter_value}" \
        --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null)
    for eni_id in ${eni_ids}; do
        echo "  Deleting ENI ${eni_id} ..."
        local att_id
        att_id=$(aws --region "$REGION" ec2 describe-network-interfaces \
            --network-interface-ids "${eni_id}" \
            --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
        if [[ -n "${att_id}" && "${att_id}" != "None" ]]; then
            aws --region "$REGION" ec2 detach-network-interface --attachment-id "${att_id}" --force 2>/dev/null || true
            sleep 5
        fi
        aws --region "$REGION" ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || true
    done
}

function cleanup_vpc()
{
    local vpc_id=$1
    echo "Cleaning up VPC ${vpc_id} dependencies ..."

    delete_enis "vpc-id" "${vpc_id}"

    local subnet_ids
    subnet_ids=$(aws --region "$REGION" ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "Subnets[].SubnetId" --output text 2>/dev/null)
    for sid in ${subnet_ids}; do
        echo "  Deleting subnet ${sid} ..."
        aws --region "$REGION" ec2 delete-subnet --subnet-id "${sid}" 2>/dev/null || true
    done

    local igw_ids
    igw_ids=$(aws --region "$REGION" ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null)
    for igw_id in ${igw_ids}; do
        echo "  Detaching and deleting IGW ${igw_id} ..."
        aws --region "$REGION" ec2 detach-internet-gateway --internet-gateway-id "${igw_id}" --vpc-id "${vpc_id}" 2>/dev/null || true
        aws --region "$REGION" ec2 delete-internet-gateway --internet-gateway-id "${igw_id}" 2>/dev/null || true
    done

    local nat_ids
    nat_ids=$(aws --region "$REGION" ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=${vpc_id}" \
        --query "NatGateways[?State!='deleted'].NatGatewayId" --output text 2>/dev/null)
    for nat_id in ${nat_ids}; do
        echo "  Deleting NAT gateway ${nat_id} ..."
        aws --region "$REGION" ec2 delete-nat-gateway --nat-gateway-id "${nat_id}" 2>/dev/null || true
        aws --region "$REGION" ec2 wait nat-gateway-deleted --nat-gateway-ids "${nat_id}" 2>/dev/null || true
    done

    local sg_ids
    sg_ids=$(aws --region "$REGION" ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)
    for sg_id in ${sg_ids}; do
        echo "  Deleting security group ${sg_id} ..."
        aws --region "$REGION" ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null || true
    done

    local rt_ids
    rt_ids=$(aws --region "$REGION" ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "RouteTables[?Associations[?Main!=\`true\`] || !Associations].RouteTableId" --output text 2>/dev/null)
    for rt_id in ${rt_ids}; do
        local rt_assocs
        rt_assocs=$(aws --region "$REGION" ec2 describe-route-tables \
            --route-table-ids "${rt_id}" \
            --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null)
        for assoc in ${rt_assocs}; do
            aws --region "$REGION" ec2 disassociate-route-table --association-id "${assoc}" 2>/dev/null || true
        done
        aws --region "$REGION" ec2 delete-route-table --route-table-id "${rt_id}" 2>/dev/null || true
    done

    aws --region "$REGION" ec2 delete-vpc --vpc-id "${vpc_id}" 2>/dev/null || true
}

function cleanup_failed_stack()
{
    local stack_name=$1

    local vpc_ids
    vpc_ids=$(aws --region "$REGION" cloudformation describe-stack-resources \
        --stack-name "${stack_name}" \
        --query "StackResources[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" \
        --output text 2>/dev/null)

    for vpc_id in ${vpc_ids}; do
        cleanup_vpc "${vpc_id}"
    done
}

function check_stack_deleted()
{
    local stack_name=$1
    local stack_status
    stack_status=$(aws --region "$REGION" cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null) || return 0

    if [[ "${stack_status}" == "DELETE_COMPLETE" ]]; then
        return 0
    fi
    return 1
}

function delete_stacks()
{
    local stack_list=$1
    local rc=0
    for stack_name in $(tac "${stack_list}"); do
        echo "Deleting stack ${stack_name} ..."
        aws --region "$REGION" cloudformation delete-stack --stack-name "${stack_name}" &
        wait "$!"
        aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
        wait "$!"

        if check_stack_deleted "${stack_name}"; then
            echo "Stack ${stack_name} deleted successfully"
            continue
        fi

        local attempt
        for attempt in 1 2; do
            echo "Stack ${stack_name} deletion failed, cleaning up VPC resources (attempt ${attempt}/2) ..."
            cleanup_failed_stack "${stack_name}"

            echo "Retrying stack deletion for ${stack_name} ..."
            aws --region "$REGION" cloudformation delete-stack --stack-name "${stack_name}" &
            wait "$!"
            aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
            wait "$!"

            if check_stack_deleted "${stack_name}"; then
                echo "Stack ${stack_name} deleted successfully on retry"
                break
            fi
        done

        if ! check_stack_deleted "${stack_name}"; then
            echo "ERROR: Failed to delete stack ${stack_name} after 2 cleanup attempts"
            rc=1
        fi
    done
    return $rc
}

echo "Deleting AWS CloudFormation stacks"

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks:"
    cat "${stack_list}"
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    delete_stacks "${stack_list}" || rc=1
fi

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list_shared_account"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks in shared account:"
    cat "${stack_list}"
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
    delete_stacks "${stack_list}" || rc=1
fi

exit ${rc:-0}
