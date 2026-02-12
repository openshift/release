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
  [us-east-1,x86_64,rhel-9.2]=ami-05f26a378a37b8fec     # RHEL-9.2.0_HVM-20250520-x86_64-0-Hourly2-GP3
  [us-east-1,arm64,rhel-9.2]=ami-047cb634268ecc0a6      # RHEL-9.2.0_HVM-20250520-arm64-0-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.4]=ami-0e078af919796acf1     # RHEL-9.4.0_HVM-20250917-x86_64-0-Hourly2-GP3
  [us-east-1,arm64,rhel-9.4]=ami-04e40399249acc576      # RHEL-9.4.0_HVM-20250917-arm64-0-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.6]=ami-03f1d522d98841360     # RHEL-9.6.0_HVM-20250910-x86_64-0-Hourly2-GP3
  [us-east-1,arm64,rhel-9.6]=ami-04db3c91a597912d6      # RHEL-9.6.0_HVM-20250910-arm64-0-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.2]=ami-0828b5584587b20b2     # RHEL-9.2.0_HVM-20250520-x86_64-0-Hourly2-GP3
  [us-west-2,arm64,rhel-9.2]=ami-0fe01cf6276fcc8c5      # RHEL-9.2.0_HVM-20250520-arm64-0-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.4]=ami-0afbb67255ef6e726     # RHEL-9.4.0_HVM-20250917-x86_64-0-Hourly2-GP3
  [us-west-2,arm64,rhel-9.4]=ami-0ff4bae26d5e7e36a      # RHEL-9.4.0_HVM-20250917-arm64-0-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.6]=ami-022daef1002763216     # RHEL-9.6.0_HVM-20250910-x86_64-0-Hourly2-GP3
  [us-west-2,arm64,rhel-9.6]=ami-0b2dc437bf4878d14      # RHEL-9.6.0_HVM-20250910-arm64-0-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.2]=ami-02ad2ca65425af1c8  # RHEL-9.2.0_HVM-20250520-x86_64-0-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.2]=ami-0334bf2525c55070d   # RHEL-9.2.0_HVM-20250520-arm64-0-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.4]=ami-0f7fa5d86c8e44172  # RHEL-9.4.0_HVM-20250917-x86_64-0-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.4]=ami-078e99bcb609a9931   # RHEL-9.4.0_HVM-20250917-arm64-0-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.6]=ami-0066d4651999e27f1  # RHEL-9.6.0_HVM-20250910-x86_64-0-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.6]=ami-0f0cd53332525ff39   # RHEL-9.6.0_HVM-20250910-arm64-0-Hourly2-GP3
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
stack_name="microshift-$(cat /proc/sys/kernel/random/uuid)"
cf_tpl_file="${SHARED_DIR}/${NAMESPACE}-cf-tpl.yaml"

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
