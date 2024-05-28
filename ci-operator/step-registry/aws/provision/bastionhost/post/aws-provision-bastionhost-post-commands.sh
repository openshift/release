#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${REGION:-$LEASED_RESOURCE}
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
BASTION_INSTANCE_ID=$(cat "${SHARED_DIR}/aws-instance-ids.txt")

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )


if (( ocp_minor_version >= 16 )); then
    echo "Since OCP-4.16, we need to add the worker security group to the bastion for later SSH connection"
    #Get the node SecurityGroup ID
    node_security_group=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=${VPC_ID} Name=group-name,Values=*node --region ${REGION} --query SecurityGroups[*].GroupId --output text)

    #Get the existing SecurityGroup IDs of Bastion 
    current_security_groups=$(aws ec2 describe-instances --region ${REGION} --instance-ids ${BASTION_INSTANCE_ID} --query Reservations[*].Instances[*].SecurityGroups[*].GroupId --output text)
    echo ${current_security_groups} > ${SHARED_DIR}/aws_bastion_sgs

    #Add the node SecurityGroup to Bastion
    aws ec2 modify-instance-attribute --region ${REGION} --instance-id ${BASTION_INSTANCE_ID} --groups ${current_security_groups} ${node_security_group}
    echo "Worker SG added to the bastion"

fi 
