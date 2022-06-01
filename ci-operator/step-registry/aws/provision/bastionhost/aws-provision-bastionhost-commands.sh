#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

REGION="${LEASED_RESOURCE}"

# Using source region for C2S and SC2S
if [[ "${CLUSTER_TYPE}" == "aws-c2s" ]] || [[ "${CLUSTER_TYPE}" == "aws-sc2s" ]]; then
  REGION=$(jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
fi

# 1. get vpc id and public subnet
VpcId=$(cat "${SHARED_DIR}/vpc_id")
echo "VpcId: $VpcId"

PublicSubnet="$(/tmp/yq r "${SHARED_DIR}/public_subnet_ids" '[0]')"
echo "PublicSubnet: $PublicSubnet"

CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
stack_name="${CLUSTER_NAME}-bas"
s3_bucket_name="${CLUSTER_NAME}-s3"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
bastion_cf_tpl_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion-cf-tpl.yaml"

curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/upi_on_aws-cloudformation-templates/99_int_service_instance.yaml -o ${bastion_cf_tpl_file}

if [[ "${BASTION_HOST_AMI}" == "" ]]; then
  # create bastion host dynamicly
  if [[ ! -f "${bastion_ignition_file}" ]]; then
    echo "'${bastion_ignition_file}' not found , abort." && exit 1
  fi
  curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/coreos-for-bastion-host/fedora-coreos-stable.json -o /tmp/fedora-coreos-stable.json
  ami_id=$(jq -r .architectures.x86_64.images.aws.regions[\"${REGION}\"].image < /tmp/fedora-coreos-stable.json)

  ign_location="s3://${s3_bucket_name}/bastion.ign"
  aws --region $REGION s3 mb "s3://${s3_bucket_name}"
  echo "s3://${s3_bucket_name}" > "$SHARED_DIR/to_be_removed_s3_bucket_list"
  aws --region $REGION s3 cp ${bastion_ignition_file} "${ign_location}"
else
  # use BYO bastion host
  ami_id=${BASTION_HOST_AMI}
  ign_location="NA"
fi

echo -e "AMI ID: $ami_id"

BastionHostInstanceType="t2.medium"
# there is no t2.medium instance type in us-gov-east-1 region
if [[ "${REGION}" == "us-gov-east-1" ]]; then
    BastionHostInstanceType="t3a.medium"
fi


# create bastion instance bucket
echo -e "==== Start to create bastion host ===="
echo ${stack_name} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region $REGION cloudformation create-stack --stack-name ${stack_name} \
    --template-body file://${bastion_cf_tpl_file} \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=VpcId,ParameterValue="${VpcId}"  \
        ParameterKey=BastionHostInstanceType,ParameterValue="${BastionHostInstanceType}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=PublicSubnet,ParameterValue="${PublicSubnet}" \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=BastionIgnitionLocation,ParameterValue="${ign_location}"  &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

echo "$stack_name" > "${SHARED_DIR}/bastion_host_stack_name"

INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
--query 'Stacks[].Outputs[?OutputKey == `BastionInstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy bastion host ID to "${SHARED_DIR}/aws-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-ids.txt"

BASTION_HOST_PUBLIC_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicDnsName`].OutputValue' --output text)"
BASTION_HOST_PRIVATE_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateDnsName`].OutputValue' --output text)"

echo "${BASTION_HOST_PUBLIC_DNS}" > "${SHARED_DIR}/bastion_public_address"
echo "${BASTION_HOST_PRIVATE_DNS}" > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

PROXY_CREDENTIAL=$(< /var/run/vault/proxy/proxy_creds)
PROXY_PUBLIC_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PUBLIC_DNS}:3128"
PROXY_PRIVATE_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PRIVATE_DNS}:3128"

echo "${PROXY_PUBLIC_URL}" > "${SHARED_DIR}/proxy_public_url"
echo "${PROXY_PRIVATE_URL}" > "${SHARED_DIR}/proxy_private_url"

MIRROR_REGISTRY_URL="${BASTION_HOST_PUBLIC_DNS}:5000"
echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
