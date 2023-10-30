#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

function aws_add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

cat > /tmp/01_firewall.yaml << EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Template for AWS network firewall'

Parameters:
  FirewallName:
    Description: The name that is using for the firewall.
    Type: String
  FirewallPolicyName:
    Description: The name that is using for the firewall policy.
    Type: String
  VpcId:
    Description: The unique identifier of the VPC where the firewall is in use.
    Type: String
  SubnetId:
    Description: The public subnets that Network Firewall is using for the firewall.
    Type: String

Resources:
  NetworkFirewall:
    Type: 'AWS::NetworkFirewall::Firewall'
    Properties:
      FirewallName: !Ref FirewallName
      VpcId: !Ref VpcId
      SubnetMappings:
        - SubnetId: !Ref SubnetId
      FirewallPolicyArn:
        Ref: FirewallPolicy
      DeleteProtection: false
      FirewallPolicyChangeProtection: false
      SubnetChangeProtection: false
      Tags:
        - Key: Name
          Value: !Ref FirewallName
  FirewallPolicy:
    Type: 'AWS::NetworkFirewall::FirewallPolicy'
    Properties:
      FirewallPolicyName: !Ref FirewallPolicyName
      FirewallPolicy:
        StatelessDefaultActions:
          - 'aws:forward_to_sfe'
        StatelessFragmentDefaultActions:
          - 'aws:forward_to_sfe'
Metadata: {}
Conditions: {}
EOF

vpc_id=$(head -n 1 ${SHARED_DIR}/vpc_id)
# public_subnet_ids=$(yq-go r -j ${SHARED_DIR}/public_subnet_ids | jq -r '[ . | join(" ") ] | @csv' | sed "s/\"//g")
private_subnet_id=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']" | cut -d ',' -f 1)
public_subnet_id=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']" | cut -d ',' -f 1)
if [[ -z $vpc_id ]] || [[ -z $public_subnet_id ]] || [[ -z $private_subnet_id ]]; then
  echo "Error: Can not get VPC id or private subnets, exit"
  echo "vpc: $vpc_id, private_subnet_ids: $private_subnet_id"
  exit 1
fi
## Prepare the private subnet for the network firewall assoication.
UNIQUE_HASH=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 4)
zone=$(aws ec2 describe-subnets --subnet-ids $private_subnet_id --query "Subnets[0].AvailabilityZone" --output text)
firewall_subnet_id=$(aws --region "${REGION}" ec2 create-subnet \
 --vpc-id $vpc_id \
 --availability-zone $zone \
 --cidr-block "10.0.112.0/20" \
 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=firewall-subnet-${UNIQUE_HASH}}]" \
 --query "Subnet.SubnetId" --output=text)

STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-firewall"
firewall_name=${STACK_NAME}
firewall_policy_name="${STACK_NAME}-policy"
firewall_params="${ARTIFACT_DIR}/firewall_params.json"
aws_add_param_to_json "VpcId" $vpc_id "$firewall_params"
aws_add_param_to_json "SubnetId" $firewall_subnet_id "$firewall_params"
aws_add_param_to_json "FirewallName" $firewall_name "$firewall_params"
aws_add_param_to_json "FirewallPolicyName" $firewall_policy_name "$firewall_params"

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_firewall.yaml)" \
  --parameters file://${firewall_params} &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"
echo "${STACK_NAME}" > "${SHARED_DIR}/firewall_stack_name"

# Save stack information to ${SHARED_DIR} for deprovision step
echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

# Save firewall output
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/firewall_stack_output"
aws --region "${REGION}" network-firewall describe-firewall-policy --firewall-policy-name $firewall_policy_name  > "${SHARED_DIR}/firewall_policy_output"
vpce_endpoint_id=$(aws --region "${REGION}" ec2 describe-vpc-endpoints \
 --filters "Name=vpc-id,Values=${vpc_id}" "Name=vpc-endpoint-type,Values=GatewayLoadBalancer" \
 --query "VpcEndpoints[0].VpcEndpointId" --output text)

# Configure the traffic routing
echo "Update the traffic route for the firewall subnet $firewall_subnet_id"
firewall_route_table_id=$(aws --region "${REGION}" ec2 create-route-table --vpc-id $vpc_id --query "RouteTable.RouteTableId" --output text)
nat_gateway_id=$(aws --region "${REGION}" ec2 describe-nat-gateways --filter "Name=subnet-id,Values=${public_subnet_id}" --query "NatGateways[0].NatGatewayId" --output text)
aws --region "${REGION}" ec2 create-route  --route-table-id $firewall_route_table_id --destination-cidr-block "0.0.0.0/0" --nat-gateway-id $nat_gateway_id
aws --region "${REGION}" ec2 associate-route-table --route-table-id $firewall_route_table_id --subnet-id $firewall_subnet_id

echo "Update the traffic route for the public subnet $public_subnet_id"
public_route_table_id=$(aws --region "${REGION}" ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${public_subnet_id}" --query "RouteTables[0].RouteTableId" --output text)
private_subnet_cidr=$(aws --region "${REGION}" ec2 describe-subnets --subnet-ids $private_subnet_id --query "Subnets[0].CidrBlock" --output text)
aws --region "${REGION}" ec2 create-route  --route-table-id $public_route_table_id --destination-cidr-block $private_subnet_cidr --vpc-endpoint-id $vpce_endpoint_id

echo "Update the traffic route for the private subnet $private_subnet_id"
private_route_table_id=$(aws --region "${REGION}" ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${private_subnet_id}" --query "RouteTables[0].RouteTableId" --output text)
aws --region "${REGION}" ec2 delete-route --route-table-id $private_route_table_id --destination-cidr-block "0.0.0.0/0" 
aws --region "${REGION}" ec2 create-route  --route-table-id $private_route_table_id --destination-cidr-block "0.0.0.0/0"  --vpc-endpoint-id $vpce_endpoint_id

echo "Disassociate the gatway vpce on the public subnet and the private subnet"
gateway_vpce_endpoint_id=$(aws --region "${REGION}" ec2 describe-vpc-endpoints \
 --filters "Name=vpc-id,Values=${vpc_id}" "Name=vpc-endpoint-type,Values=Gateway" \
 --query "VpcEndpoints[0].VpcEndpointId" --output text)
aws --region "${REGION}" ec2 modify-vpc-endpoint --vpc-endpoint-id $gateway_vpce_endpoint_id --remove-route-table-ids $public_route_table_id $private_route_table_id

echo "Finish network firewall configuration on vpc $vpc_id"

echo $private_subnet_id > "${SHARED_DIR}/subnet_id_for_firewall"
cp "${SHARED_DIR}/subnet_id_for_firewall" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/firewall_stack_name" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/firewall_policy_output" "${ARTIFACT_DIR}/"
