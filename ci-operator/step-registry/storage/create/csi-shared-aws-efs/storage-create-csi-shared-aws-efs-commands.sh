#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

set -x

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

switch_aws_credentials() {
  local mode="$1"
  if [[ "$mode" == "shared" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
    logger "INFO" "Using shared AWS account(B)."
  else
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    logger "INFO" "Using default AWS account(A)."
  fi
}

REGION="${REGION:-$LEASED_RESOURCE}"
if [ -z "$REGION" ]; then
  logger "Error" "REGION is not set and LEASED_RESOURCE is empty."
  exit 1
fi

export AWS_DEFAULT_REGION="$REGION"
logger "INFO" "Using AWS region: $AWS_DEFAULT_REGION"

switch_aws_credentials default
AWS_ACCOUNT_A_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
AWS_ACCOUNT_A_ID=$(echo "$AWS_ACCOUNT_A_ARN" | awk -F ":" '{print $5}') || return 1
export AWS_ACCOUNT_A_ID
INSTANCE_ID=$(oc get nodes -o jsonpath='{.items[0].spec.providerID}' | cut -d'/' -f5)
AWS_ACCOUNT_A_VPC_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --output json | jq -r '.Reservations[0].Instances[0].VpcId')
AWS_ACCOUNT_A_VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "$AWS_ACCOUNT_A_VPC_ID" \
  --output json | jq -r '.Vpcs[0].CidrBlock')
switch_aws_credentials shared
AWS_ACCOUNT_B_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
AWS_ACCOUNT_B_ID=$(echo "$AWS_ACCOUNT_B_ARN" | awk -F ":" '{print $5}') || return 1
export AWS_ACCOUNT_B_ID
CLUSTER_NAME="$(jq -r .clusterName "${SHARED_DIR}/metadata.json")"


# Get the VPC ID from the shared account
AWS_ACCOUNT_B_VPC_ID=$(cat "${SHARED_DIR}/vpc_id")

# Creating a region-wide EFS filesystem in Account B
ACROSS_ACCOUNT_FS_ID=$(aws efs create-file-system --creation-token "${CLUSTER_NAME}"-ci-cross-account-token \
   --region "${AWS_DEFAULT_REGION}" \
   --encrypted | jq -r '.FileSystemId')
logger "INFO" "Created efs volume FileSystemId:$ACROSS_ACCOUNT_FS_ID"
echo "${ACROSS_ACCOUNT_FS_ID}" > "${SHARED_DIR}/fileSystemId"

# Prepare the security groups on Account B to allow NFS traffic to EFS
AWS_ACCOUNT_B_VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "$AWS_ACCOUNT_B_VPC_ID" \
  --output json | jq -r '.Vpcs[0].CidrBlock')
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$AWS_ACCOUNT_B_VPC_ID" | jq -r '.SecurityGroups[].GroupId')
aws ec2 authorize-security-group-ingress \
 --group-id "$SECURITY_GROUP_ID" \
 --protocol tcp \
 --port 2049 \
 --cidr "$AWS_ACCOUNT_A_VPC_CIDR" | jq .

# Configure a region-wide Mount Target for EFS (this will create a mount point in each subnet of your VPC by default)
AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS=$(sed -e "s/[][]//g" -e "s/','/ /g" -e "s/'//g" "${SHARED_DIR}/private_subnet_ids")
for SUBNET in $AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS; do \
    MOUNT_TARGET=$(aws efs create-mount-target --file-system-id "$ACROSS_ACCOUNT_FS_ID" \
       --subnet-id "$SUBNET" \
       --region "$AWS_DEFAULT_REGION" \
       | jq -r '.MountTargetId'); \
    logger "INFO" "Created $MOUNT_TARGET for $SUBNET"; \
 done

MAX_WAIT_SECONDS=180
SLEEP_INTERVAL=5
logger "INFO" "Waiting up to 3 minutes for all mount targets to become available..."

START_TIME=$(date +%s)

while true; do
  STATUS_LIST=$(aws efs describe-mount-targets \
    --file-system-id "$ACROSS_ACCOUNT_FS_ID" \
    --region "$REGION")

  NOT_READY=$(echo "$STATUS_LIST" | jq -r '[.MountTargets[].LifeCycleState] | map(select(. != "available")) | length')
  logger "INFO" "Mount targets not ready: $NOT_READY"

  if [[ "$NOT_READY" -eq 0 ]]; then
    logger "INFO" "All mount targets are available...."
    break
  fi

  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  if (( ELAPSED >= MAX_WAIT_SECONDS )); then
    logger "ERROR" "Timeout: Not all mount targets became available within 3 minutes."
    exit 1
  fi

  sleep $SLEEP_INTERVAL
done

# Create VPC peering between the Red Hat OpenShift cluster VPC in AWS account A and the AWS EFS VPC in AWS account B
PEER_REQUEST_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "${AWS_ACCOUNT_B_VPC_ID}" \
  --peer-vpc-id "${AWS_ACCOUNT_A_VPC_ID}" \
  --peer-owner-id "${AWS_ACCOUNT_A_ID}" \
  --output json | jq -r '.VpcPeeringConnection.VpcPeeringConnectionId')

switch_aws_credentials default
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "${PEER_REQUEST_ID}"
SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="${AWS_ACCOUNT_A_VPC_ID}" \
  | jq -r '.Subnets[].SubnetId')

sleep 8h

for subnet in $SUBNETS; do
  # Get route table associated with this subnet (specific or main)
  RTB=$(aws ec2 describe-route-tables \
    --filters Name=association.subnet-id,Values="$subnet" \
    | jq -r '.RouteTables[0].RouteTableId')

  if [ "$RTB" == "null" ]; then
    # No subnet-specific route table, fall back to main route table
    RTB=$(aws ec2 describe-route-tables \
      --filters Name=vpc-id,Values="${AWS_ACCOUNT_A_VPC_ID}" Name=association.main,Values=true \
      | jq -r '.RouteTables[0].RouteTableId')
  fi

  # Check if the route table has a route to an Internet Gateway
  HAS_IGW=$(aws ec2 describe-route-tables --route-table-ids "$RTB" \
    | jq -e '.RouteTables[0].Routes[] | select(.GatewayId | startswith("igw-"))' > /dev/null && echo "yes" || echo "no")

  # If no IGW, it's private
  if [ "$HAS_IGW" == "no" ]; then
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET}" --query 'RouteTables[*].RouteTableId' | jq -r '.[0]')
    aws ec2 create-route --route-table-id "${ROUTE_TABLE_ID}" --destination-cidr-block "${AWS_ACCOUNT_B_VPC_CIDR}" --vpc-peering-connection-id "${PEER_REQUEST_ID}"
    logger "INFO" "Created route for $SUBNET to peering-connection in account A"
  fi
done

switch_aws_credentials shared
for SUBNET in $AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS; do 
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET}" --query 'RouteTables[*].RouteTableId' | jq -r '.[0]')
  aws ec2 create-route --route-table-id "${ROUTE_TABLE_ID}" --destination-cidr-block "${AWS_ACCOUNT_A_VPC_CIDR}" --vpc-peering-connection-id "${PEER_REQUEST_ID}"
  logger "INFO" "Created route for $SUBNET to peering-connection in account B"
done

cat << EOF > "${SHARED_DIR}"/EfsPolicyInAccountB.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeSubnets"
            ],
            "Resource": "*"
        },
        {
            "Sid": "VisualEditor1",
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:DescribeMountTargets",
                "elasticfilesystem:DeleteAccessPoint",
                "elasticfilesystem:ClientMount",
                "elasticfilesystem:DescribeAccessPoints",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientRootAccess",
                "elasticfilesystem:DescribeFileSystems",
                "elasticfilesystem:CreateAccessPoint"
            ],
            "Resource": [
                "arn:aws:elasticfilesystem:*:${AWS_ACCOUNT_B_ID}:access-point/*",
                "arn:aws:elasticfilesystem:*:${AWS_ACCOUNT_B_ID}:file-system/*"
            ]
        }
    ]
}
EOF

cat <<EOF > "${SHARED_DIR}"/TrustPolicyInAccountB.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT_A_ID}:root"
            },
            "Action": "sts:AssumeRole",
            "Condition": {}
        }
    ]
}
EOF

ACCOUNT_B_POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-efs-csi" \
   --policy-document file://"${SHARED_DIR}"/efs-policy.json \
   --query 'Policy.Arn' --output text) || \
logger "INFO" "Created efs policy $ACCOUNT_B_POLICY in account B"

# Create Role for the EFS CSI Driver Operator
ACCOUNT_B_ROLE_ARN=$(aws iam create-role \
  --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
  --assume-role-policy-document file://"${SHARED_DIR}"/TrustPolicy.json \
  --query "Role.Arn" --output text)
logger "INFO" "Created efs csi driver role $ACCOUNT_B_ROLE_ARN in account B"

aws iam attach-role-policy \
   --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
   --policy-arn "${ACCOUNT_B_POLICY}"
logger "INFO" "Attach the Policies to the Role in account B"

sleep 6h