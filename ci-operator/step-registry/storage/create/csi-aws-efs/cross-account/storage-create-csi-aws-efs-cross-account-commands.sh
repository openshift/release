#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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

if [[ ! -f "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
  logger "ERROR: The efs cross account is enabled, but the 2nd AWS account credential file \${CLUSTER_PROFILE_DIR}/.awscred_shared_account file does not exit, please check your cluster profile."
  exit 1
fi

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
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE="openshift-cluster-csi-drivers"


# Get the VPC ID from the shared account
AWS_ACCOUNT_B_VPC_ID=$(cat "${SHARED_DIR}/vpc_id")

# STEP. Creating a region-wide EFS filesystem in Account B
CROSS_ACCOUNT_FS_ID=$(aws efs create-file-system --creation-token "${CLUSTER_NAME}"-ci-cross-account-token \
   --encrypted | jq -r '.FileSystemId')
logger "INFO" "Created efs volume FileSystemId:$CROSS_ACCOUNT_FS_ID"
echo "${CROSS_ACCOUNT_FS_ID}" > "${SHARED_DIR}"/cross_account_fs_id

# STEP. Prepare the security groups on Account B to allow account A NFS traffic to EFS
AWS_ACCOUNT_B_VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "$AWS_ACCOUNT_B_VPC_ID" \
  --output json | jq -r '.Vpcs[0].CidrBlock')
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$AWS_ACCOUNT_B_VPC_ID" | jq -r '.SecurityGroups[].GroupId')
aws ec2 authorize-security-group-ingress \
 --group-id "$SECURITY_GROUP_ID" \
 --protocol tcp \
 --port 2049 \
 --cidr "$AWS_ACCOUNT_A_VPC_CIDR" | jq .

MAX_WAIT_SECONDS=180
SLEEP_INTERVAL=5

START_TIME=$(date +%s)
# Wait for the EFS file system to become available to avoid 
# "An error occurred (IncorrectFileSystemLifeCycleState) when calling the CreateMountTarget operation: None"
while true; do
  STATE=$(aws efs describe-file-systems \
    --file-system-id "${CROSS_ACCOUNT_FS_ID}" \
    --query "FileSystems[0].LifeCycleState" \
    --output text)
  logger "INFO" "EFS file system current state is $STATE ..."

  if [ "$STATE" == "available" ]; then
    logger "INFO" "EFS file system is now available ..."
    break
  fi
  
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  logger "INFO" "EFS file system is not ready yet. Sleeping $SLEEP_INTERVAL seconds..."
  if (( ELAPSED >= MAX_WAIT_SECONDS )); then
    logger "ERROR" "Timeout: EFS file system does not became available within 3 minutes."
    exit 1
  fi

  sleep $SLEEP_INTERVAL
done

# STEP. Configure a region-wide Mount Target for EFS in account B
AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS=$(sed -e "s/[][]//g" -e "s/','/ /g" -e "s/'//g" "${SHARED_DIR}/private_subnet_ids")
if [[ ${EFS_ENABLE_SINGLE_ZONE} == "true" ]]; then
  SINGLE_ZONE=$(oc get node -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}')
  AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=availability-zone,Values=$SINGLE_ZONE" "Name=vpc-id,Values=$AWS_ACCOUNT_B_VPC_ID" \
  --query "Subnets[*].SubnetId" \
  --output text)
fi

for SUBNET in $AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS; do \
    MOUNT_TARGET=$(aws efs create-mount-target --file-system-id "$CROSS_ACCOUNT_FS_ID" \
       --subnet-id "$SUBNET" \
       | jq -r '.MountTargetId'); \
    logger "INFO" "Created $MOUNT_TARGET for $SUBNET"; \
done

logger "INFO" "Waiting up to 3 minutes for all mount targets to become available..."

START_TIME=$(date +%s)

while true; do
  STATUS_LIST=$(aws efs describe-mount-targets \
    --file-system-id "$CROSS_ACCOUNT_FS_ID")

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

# STEP. Create VPC peering between the OpenShift cluster VPC in account A and the aws efs volume VPC in AWS account B
PEER_REQUEST_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id "${AWS_ACCOUNT_B_VPC_ID}" \
  --peer-vpc-id "${AWS_ACCOUNT_A_VPC_ID}" \
  --peer-owner-id "${AWS_ACCOUNT_A_ID}" \
  --output json | jq -r '.VpcPeeringConnection.VpcPeeringConnectionId')
echo "${PEER_REQUEST_ID}" > "$SHARED_DIR"/vpc_peering_id

switch_aws_credentials default
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "${PEER_REQUEST_ID}"
SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="${AWS_ACCOUNT_A_VPC_ID}" \
  | jq -r '.Subnets[].SubnetId')

for subnet in $SUBNETS; do
  # Get route table associated with this subnet (specific or main)
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters Name=association.subnet-id,Values="$subnet" \
    | jq -r '.RouteTables[0].RouteTableId')

  if [ "$ROUTE_TABLE_ID" == "null" ]; then
    # No subnet-specific route table, fall back to main route table
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
      --filters Name=vpc-id,Values="${AWS_ACCOUNT_A_VPC_ID}" Name=association.main,Values=true \
      | jq -r '.RouteTables[0].RouteTableId')
  fi

  # Check if the route table has a route to an Internet Gateway
  HAS_IGW=$(aws ec2 describe-route-tables --route-table-ids "${ROUTE_TABLE_ID}" \
    | jq -e '.RouteTables[0].Routes[]? | select((.GatewayId | type == "string") and (.GatewayId | startswith("igw-")))' \
  > /dev/null && echo "yes" || echo "no")

  # If no IGW, it's private
  if [ "$HAS_IGW" == "no" ]; then
    aws ec2 create-route --route-table-id "${ROUTE_TABLE_ID}" --destination-cidr-block "${AWS_ACCOUNT_B_VPC_CIDR}" --vpc-peering-connection-id "${PEER_REQUEST_ID}"
    logger "INFO" "Created route for ${subnet} to peering-connection in account A"
  fi
done

switch_aws_credentials shared
for SUBNET in $AWS_ACCOUNT_B_PRIVATE_SUBNET_IDS; do 
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET}" --query 'RouteTables[*].RouteTableId' | jq -r '.[0]')
  aws ec2 create-route --route-table-id "${ROUTE_TABLE_ID}" --destination-cidr-block "${AWS_ACCOUNT_A_VPC_CIDR}" --vpc-peering-connection-id "${PEER_REQUEST_ID}"
  logger "INFO" "Created route for ${SUBNET} to peering-connection in account B"
done


# STEP. Create an IAM role in Account B which has a trust relationship with Account A(assume-role-policy) and 
# add an EFS policy with necessary permissions, then attach the policy to the role.
cat <<EOF > "${SHARED_DIR}"/AssumeRolePolicyInAccountB.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT_A_ID}:root"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF


ACCOUNT_B_ROLE_NAME="${CLUSTER_NAME}-cross-account-aws-efs-csi-operator"
ACCOUNT_B_ROLE_ARN=$(aws iam create-role \
  --role-name "${ACCOUNT_B_ROLE_NAME}" \
  --assume-role-policy-document file://"${SHARED_DIR}"/AssumeRolePolicyInAccountB.json \
  --query "Role.Arn" --output text)
logger "INFO" "Created efs csi driver operator role ${ACCOUNT_B_ROLE_ARN} and trust policy allows a role from account A to assume this new role in account B"
echo "${ACCOUNT_B_ROLE_ARN}" > "${SHARED_DIR}"/cross-account-efs-csi-driver-operator-role-arn

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
                "elasticfilesystem:CreateAccessPoint",
                "elasticfilesystem:TagResource"
            ],
            "Resource": "*"
        }
    ]
}
EOF
ACCOUNT_B_POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-efs-csi-policy" \
   --policy-document file://"${SHARED_DIR}"/EfsPolicyInAccountB.json \
   --query 'Policy.Arn' --output text) || \
logger "INFO" "Created efs policy ${ACCOUNT_B_POLICY} in account B"

aws iam attach-role-policy \
   --role-name "${ACCOUNT_B_ROLE_NAME}" \
   --policy-arn "${ACCOUNT_B_POLICY}"
logger "INFO" "Attach the Policies to the Role in account B"

# STEP. In aws account A, attach an inline policy to IAM role of efs-csi-driver's controller service account 
# with necessary permissions to perform sts assume role which created in account B.
switch_aws_credentials default
cat <<EOF > "${SHARED_DIR}"/AssumeRoleInlinePolicyPolicyInAccountA.json
{
    "Version": "2012-10-17",
    "Statement": {
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Resource": "${ACCOUNT_B_ROLE_ARN}"
    }
}
EOF

# STS standlone cluster the operator installed with specified role
if [[ -s "${SHARED_DIR}/efs-csi-driver-operator-role-arn" ]]; then
  EFS_CSI_DRIVER_OPERATOR_ROLE_ARN=$(cat "${SHARED_DIR}"/efs-csi-driver-operator-role-arn)
  aws iam put-role-policy \
    --role-name "$(basename "${EFS_CSI_DRIVER_OPERATOR_ROLE_ARN}")"  \
    --policy-name efs-cross-account-inline-policy \
    --policy-document file://"${SHARED_DIR}"/AssumeRoleInlinePolicyPolicyInAccountA.json
  logger "INFO" "Attach the inline Policies to the efs csi driver operator Role $EFS_CSI_DRIVER_OPERATOR_ROLE_ARN in account A"
else
  # Non STS standlone cluster the operator uses the credentialsrequest user
  EFS_CSI_DRIVER_OPERATOR_IAM_USER=$(oc -n openshift-cloud-credential-operator get credentialsrequest/openshift-aws-efs-csi-driver -o json | jq -r '.status.providerStatus.user')
  aws iam put-user-policy \
    --user-name "${EFS_CSI_DRIVER_OPERATOR_IAM_USER}"  \
    --policy-name efs-cross-account-inline-policy \
    --policy-document file://"${SHARED_DIR}"/AssumeRoleInlinePolicyPolicyInAccountA.json
  logger "INFO" "Attach the inline Policies to the efs csi driver operator user $EFS_CSI_DRIVER_OPERATOR_IAM_USER in account A"
fi

# STEP. Add the efs full access to master/control plane role which used for driver controller delete volume(access point)
aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}"-master-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemClientFullAccess
logger "INFO" "Attach the AmazonElasticFileSystemClientFullAccesse Policy to the cluster master role in account A"

# STEP. Create a secret with awsRoleArn as the key and ACCOUNT_B_ROLE_ARN as the value, add secret access permission for the aws-efs-csi-driver-controller-sa
oc create -n "${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}" secret generic efs-csi-cross-account --from-literal=awsRoleArn="${ACCOUNT_B_ROLE_ARN}"
oc create -n "${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}" role efs-controller-access-secrets --verb=get,list,watch --resource=secrets
oc create -n "${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}" rolebinding efs-controller-access-secrets-rolebinding --role=efs-controller-access-secrets --serviceaccount="${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}:aws-efs-csi-driver-controller-sa"

# STEP. Create a cross account efs csi storageclass which consumed by csi e2e tests
cat <<EOF > "${SHARED_DIR}"/efs-sc.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${CROSS_ACCOUNT_FS_ID}"
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/account-a-data"
  csi.storage.k8s.io/provisioner-secret-name: efs-csi-cross-account
  csi.storage.k8s.io/provisioner-secret-namespace: ${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}
volumeBindingMode: Immediate
EOF

# Add allowedTopologies for single zone configuration
if [[ ${EFS_ENABLE_SINGLE_ZONE} == "true" ]]; then
  cat <<EOF > "${SHARED_DIR}"/efs-sc.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${CROSS_ACCOUNT_FS_ID}"
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/account-a-data"
  csi.storage.k8s.io/provisioner-secret-name: efs-csi-cross-account
  csi.storage.k8s.io/provisioner-secret-namespace: ${EFS_CSI_DRIVER_OPERATOR_INSTALLED_NAMESPACE}
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - ${SINGLE_ZONE}
EOF
fi

logger "INFO" "Using storageclass ${SHARED_DIR}/efs-sc.yaml"
cat "${SHARED_DIR}"/efs-sc.yaml

oc create -f "${SHARED_DIR}"/efs-sc.yaml
logger "INFO" "Created storageclass from file ${SHARED_DIR}/efs-sc.yaml"
