#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_NAME=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.name')
echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"

VPC=aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,PrivateIpAddress,PublicIpAddress, PrivateDnsName, VpcId]' --output text | column -t | grep $CLUSTER_NAME | awk '{print $7}' | grep -v '^$' | sort -u
echo "VPC ID $VPC"

for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json | jq -r .SecurityGroups[].GroupId); 
do
    echo "Adding rule to SG $sg"
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 10000-20000 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol udp --port 10000-20000 --cidr 0.0.0.0/0
done



