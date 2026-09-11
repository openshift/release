#!/bin/bash

set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function retry() {
    local check_func=$1
    shift
    local max_retries=30
    local retry_delay=60
    local retries=0

    echo "retry $check_func"
    while (( retries < max_retries )); do
        if $check_func "$@"; then
            return 0
        fi

        retries=$(( retries + 1 ))
        if (( retries < max_retries )); then
            echo "Retrying in $retry_delay seconds..."
            sleep $retry_delay
        fi
    done

    echo "retry timeout after $max_retries attempts."
    return 1
}

function check_vpc_peering_connection() {
    local connection_id=$1
     peering_status_code=$(aws ec2 describe-vpc-peering-connections --vpc-peering-connection-ids ${connection_id} --region ${REGION} | jq -r '.VpcPeeringConnections[0].Status.Code')
      if [[ "${peering_status_code}" != "active" ]]; then
        echo "vpc peering status is ${peering_status_code} between ${mgmt_vpc_id} and hc vpc ${hc_vpc_id}"
        return 1
      fi
      echo "vpc peering is active now between capi mgmt vpc ${mgmt_vpc_id} and hc vpc ${hc_vpc_id}"
      return 0
}

set_proxy

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# get capi mgmt cluster vpc and subnet info, subnet list format is "subnet1,subnet2,subnet3"
mgmt_vpc_id=""
mgmt_private_subnets=""
if [[ "${MANAGEMENT_CLUSTER_TYPE}" == "ipi" ]]; then
  infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
  echo "Looking up IDs for VPC ${infra_id} and private subnet list"
    mgmt_vpc_id=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=tag:"Name",Values=${infra_id}-vpc --query 'Vpcs[0].VpcId' --output text)
    mgmt_private_subnets=$(aws --region ${REGION} ec2 describe-subnets --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=tag:Name,Values=*private*" --query 'Subnets[].SubnetId' --output text | tr ' \t' ',' )
else
  echo "now only support ipi capi mgmt cluster"
  exit 1
fi

# get capi hosted cluster vpc, subnet info and vpc cidr
  hc_vpc_id=$(cat "${SHARED_DIR}/vpc_id")
  hc_private_subnets=$(cat "${SHARED_DIR}/private_subnet_ids")
  mgmt_vpc_cidr=$(aws ec2 describe-vpcs --region ${REGION} --vpc-ids ${mgmt_vpc_id}  --query 'Vpcs[].CidrBlock' --output text)
  hc_vpc_cidr=$(aws ec2 describe-vpcs --region ${REGION} --vpc-ids ${hc_vpc_id}  --query 'Vpcs[].CidrBlock' --output text)

# create vpc peering
peering_req_result=$(aws ec2 create-vpc-peering-connection --region ${REGION} --vpc-id ${mgmt_vpc_id} --peer-vpc-id ${hc_vpc_id})
connection_id=$(echo ${peering_req_result} | jq -r '.VpcPeeringConnection.VpcPeeringConnectionId')
aws ec2 accept-vpc-peering-connection --region ${REGION} --vpc-peering-connection-id ${connection_id}
retry check_vpc_peering_connection ${connection_id}
echo ${connection_id} > "$SHARED_DIR/vpc_peering_id"

# add peering destination route for the private subnet of mgmt cluster if the target is the cidr of hc vpc
mgmt_rt_ids=$(aws ec2 describe-route-tables --region ${REGION} --filters "Name=association.subnet-id,Values=${mgmt_private_subnets}" | jq -r '.RouteTables[].RouteTableId')
for rt_id in ${mgmt_rt_ids} ; do
  rc=$(aws ec2 create-route --region ${REGION} --route-table-id ${rt_id}  --destination-cidr-block ${hc_vpc_cidr} --vpc-peering-connection-id ${connection_id})
  if [[ ! "${rc}" =~ "true" ]]; then
     echo "mgmt create-route error， result is ${rc}"
     exit 1
  fi
done

# add peering destination route for the private subnet of hc if the target is the cidr of mgmt vpc
hc_rt_ids=$(aws ec2 describe-route-tables --region ${REGION} --filters "Name=association.subnet-id,Values=${hc_private_subnets}" | jq -r '.RouteTables[].RouteTableId')
for rt_id in ${hc_rt_ids} ; do
  rc=$(aws ec2 create-route --region ${REGION} --route-table-id ${rt_id}  --destination-cidr-block ${mgmt_vpc_cidr} --vpc-peering-connection-id ${connection_id})
  if [[ ! "${rc}" =~ "true" ]]; then
    echo "hc create-route error， result is ${rc}"
    exit 1
  fi
done

# If the hosted cluster has been created, update the default security group to enable access from the management cluster's CAPI controller to the hosted cluster's API server.
# in a standard rosa hcp, apiserver port is always 443, we need to expose 443 to the ip range of mgmt cidr.
# capi kubeconfig is needed here to check capi resources
cluster_id=$(cat "${SHARED_DIR}/cluster-id")
dft_security_group_id=$(aws ec2 describe-security-groups --region ${REGION} --filters "Name=vpc-id,Values=${hc_vpc_id}" "Name=group-name,Values=${cluster_id}-default-sg" --query 'SecurityGroups[].GroupId' --output text)
aws ec2 authorize-security-group-ingress --region ${REGION} --group-id ${dft_security_group_id} --protocol tcp --port 443 --cidr ${mgmt_vpc_cidr}

echo "${dft_security_group_id}" > ${SHARED_DIR}/capi_hcp_default_security_group
echo "vpc-peering config done"
