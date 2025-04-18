#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_AWS_EC2_FAILURE

# Available regions to create the stack. These are ordered by price per instance per hour as of 07/2024.
declare regions=(us-west-2 us-east-1 eu-central-1)
# Use the first region in the list, as it should be the most stable, as the one where to push/pull caching
# results. This is done because of costs as cross-region traffic is expensive.
CACHE_REGION="${regions[0]}"

# This map should be extended everytime AMIs from different regions/architectures/os versions
# are added.
# Command to get AMIs without using WebUI/AWS console:
# aws ec2 describe-images --region $region --filters 'Name=name,Values=RHEL-9.*' --query 'Images[*].[Name,ImageId,Architecture]' --output text | sort --reverse
declare -A ami_map=(
  [us-east-1,x86_64,rhel-9.2]=ami-06e4f11a19a9d5f45     # RHEL-9.2.0_HVM-20250326-x86_64-0-Hourly2-GP3
  [us-east-1,arm64,rhel-9.2]=ami-0eb9f0269aced4aa7      # RHEL-9.2.0_HVM-20250326-arm64-0-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.3]=ami-0fc8883cbe9d895c8     # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [us-east-1,arm64,rhel-9.3]=ami-0677a1dd1ad031d74      # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.4]=ami-026b323c6b44bfe01     # RHEL-9.4.0_HVM-20250408-x86_64-0-Hourly2-GP3
  [us-east-1,arm64,rhel-9.4]=ami-049c8efe36a960c28      # RHEL-9.4.0_HVM-20250408-arm64-0-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.2]=ami-06d931ad408f7676a     # RHEL-9.2.0_HVM-20250326-x86_64-0-Hourly2-GP3
  [us-west-2,arm64,rhel-9.2]=ami-0641c0bb373b15e10      # RHEL-9.2.0_HVM-20250326-arm64-0-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.3]=ami-0c2f1f1137a85327e     # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [us-west-2,arm64,rhel-9.3]=ami-04379fa947a959c92      # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.4]=ami-041e1d038c8c67b05     # RHEL-9.4.0_HVM-20250408-x86_64-0-Hourly2-GP3
  [us-west-2,arm64,rhel-9.4]=ami-00125a61380c8e5c0      # RHEL-9.4.0_HVM-20250408-arm64-0-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.2]=ami-01aa3cac055c3f767  # RHEL-9.2.0_HVM-20250326-x86_64-0-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.2]=ami-0a59f6776aafe99c4   # RHEL-9.2.0_HVM-20250326-arm64-0-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.3]=ami-0955dc0147853401b  # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.3]=ami-0ea2a765094f230d5   # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.4]=ami-018fddf60318c369b  # RHEL-9.4.0_HVM-20250408-x86_64-0-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.4]=ami-0608096332a0a4739   # RHEL-9.4.0_HVM-20250408-arm64-0-Hourly2-GP3
)

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
if [ -f "${MICROSHIFT_CLUSTERBOT_SETTINGS}" ]; then
  : Overriding step defaults by sourcing clusterbot settings
  # shellcheck disable=SC1090
  source "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
fi

# All graviton instances have a lower case g in the family part. Using
# this we avoid adding the full map here.
ARCH="x86_64"
if [[ "${EC2_INSTANCE_TYPE%.*}" =~ .+"g".* ]]; then
  ARCH="arm64"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=""
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

curl -o "${cf_tpl_file}" https://raw.githubusercontent.com/openshift/microshift/refs/heads/main/scripts/aws/cf-gen.yaml

ec2Type="VirtualMachine"
if [[ "$EC2_INSTANCE_TYPE" =~ metal ]]; then
  ec2Type="MetalMachine"
fi
instance_type=${EC2_INSTANCE_TYPE}

curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
  unzip -q awscliv2.zip
rm -rf awscliv2.zip

aws="${PWD}/aws/dist/aws"

function save_stack_events_to_shared()
{
  set +o errexit
  "${aws}" --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.${REGION}.json"
  set -o errexit
}

for aws_region in "${regions[@]}"; do
  REGION="${aws_region}"
  echo "Current region: ${REGION}"
  ami_id="${ami_map[$REGION,$ARCH,$MICROSHIFT_OS]}"

  if "${aws}" --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
    --query "Stacks[].Outputs[?OutputKey == 'InstanceId'].OutputValue" > /dev/null; then
      echo "Appears that stack ${stack_name} already exists"
      "${aws}" --region $REGION cloudformation delete-stack --stack-name "${stack_name}"
      echo "Deleted stack ${stack_name}"
      "${aws}" --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}"
      echo "Waited for stack-delete-complete ${stack_name}"
  fi

  echo -e "${REGION} ${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

  if "${aws}" --region "$REGION" cloudformation create-stack --stack-name "${stack_name}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HostInstanceType,ParameterValue="${instance_type}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=EC2Type,ParameterValue="${ec2Type}" \
        ParameterKey=StackLaunchTemplate,ParameterValue="${stack_name}-launch-template" \
        ParameterKey=PublicKeyString,ParameterValue="$(cat ${CLUSTER_PROFILE_DIR}/ssh-publickey)" && \
    "${aws}" --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"; then

      echo "Stack created"
      set -e
      # shellcheck disable=SC2016
      INSTANCE_ID="$("${aws}" --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
      echo "Instance ${INSTANCE_ID}"
      echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-id"
      # shellcheck disable=SC2016
      HOST_PUBLIC_IP="$("${aws}" --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
      # shellcheck disable=SC2016
      HOST_PRIVATE_IP="$("${aws}" --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"
      # shellcheck disable=SC2016
      IPV6_ADDRESS="$("${aws}" --region "${REGION}" ec2 describe-instances --instance-id "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].[Ipv6Addresses[*].Ipv6Address]' --output text)"

      echo "${HOST_PUBLIC_IP}" > "${SHARED_DIR}/public_address"
      echo "${HOST_PRIVATE_IP}" > "${SHARED_DIR}/private_address"
      echo "${IPV6_ADDRESS}" > "${SHARED_DIR}/public_ipv6_address"
      echo "ec2-user" > "${SHARED_DIR}/ssh_user"
      echo "${CACHE_REGION}" > "${SHARED_DIR}/cache_region"

      ci_script_prologue
      scp -F "${HOME}/.ssh/config" "ec2-user@${HOST_PUBLIC_IP}:/tmp/init_output.txt" "${ARTIFACT_DIR}/init_ec2_output.txt"

      echo "Waiting up to 5 min for RHEL host to be up."
      timeout 5m "${aws}" --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
      exit 0
  fi
  save_stack_events_to_shared
  # Get reason for creation failure and print for quicker debugging
  jq -r '.StackEvents[] | select (.ResourceStatus == "CREATE_FAILED" and .ResourceStatusReason != "Resource creation cancelled") | { timestamp: .Timestamp, reason: .ResourceStatusReason }' "${ARTIFACT_DIR}/stack-events-${stack_name}.${REGION}.json"
done

echo "Unable to create stack in any of the regions."
exit 1
