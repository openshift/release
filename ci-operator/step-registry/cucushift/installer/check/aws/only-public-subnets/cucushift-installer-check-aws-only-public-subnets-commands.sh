#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
ret=0

function subnet_public_or_private() {
	local subnet_id="$1" subnet_type gateway
	subnet_type=""
	gateway=$(aws --region ${REGION} ec2 describe-route-tables --filter "Name=association.subnet-id,Values=${subnet_id}" --query "RouteTables[].Routes[]" | jq -rc '.[]|select(.DestinationCidrBlock=="0.0.0.0/0")')
	if [[ "${gateway}" =~ NatGatewayId.*:.*nat- ]]; then
		subnet_type="private"
	elif [[ "${gateway}" =~ GatewayId.*:.*igw- ]]; then
		subnet_type="public"
	fi
	echo "${subnet_type}"
}

vpc_id=$(aws --region ${REGION} ec2 describe-vpcs --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" | jq -r '.Vpcs[].VpcId')
if [[ -z "${vpc_id}" ]]; then
	echo "no VPC with kubernetes.io/cluster/${infra_id}=owned tag found !"
	exit 1
fi

aws --region ${REGION} ec2 describe-subnets --filter "Name=vpc-id,Values=${vpc_id}" | tee "${ARTIFACT_DIR}/vpc.json"
subnets=$(jq -r '.Subnets[].SubnetId' "${ARTIFACT_DIR}/vpc.json")
if [[ -z "${subnets}" ]]; then
	echo "No associated subnets founds !"
	exit 1
fi

natgateway_cnt=$(aws --region ${REGION} ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${vpc_id}" | jq -r ".NatGateways|length")
if (( $natgateway_cnt > 0 )); then
	echo "Found Nat Gateway:"
	ret=1
	aws --region ${REGION} ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${vpc_id}" | jq -r ".NatGateways[].NatGatewayId" | xargs
	echo "This is unexpected !"
fi

pubic_or_private=""
for subnet in ${subnets}; do
	subnet_name=$(jq -r --arg s $subnet '.Subnets[]|select(.SubnetId==$s)|.Tags[]|select(.Key=="Name").Value' "${ARTIFACT_DIR}/vpc.json")
	pubic_or_private=$(subnet_public_or_private "${subnet}")
	echo "${subnet} ----> ${subnet_name}: ${pubic_or_private}"
	if [[ "${pubic_or_private}" == "private" ]]; then
		echo "${subnet} is a private subnet, this is unexpected !"
		ret=1
	fi
done

exit $ret
