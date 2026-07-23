#!/usr/bin/env bash

#
# UPI install on AWS using CloudFormation.
#
# input: ignition files
# output:
# - infrastructure created on AWS
# - cloudformation stack ARNs saved in control files to deprovision steps
#
# TODO(mtulio): this step is based on upi-install-aws-cluster. To merge both,
# the openshift-install commands (conf/ignition) must be moved moved to pre-steps there.
# To Dos:
# 1/ make the UPI step upi-install-aws-cluster generic (openshift-install agnostic, like this)
# 2/ merge this step with upi-install-aws-cluster
# 3/ move to CloudFormation stack set deployment creating a one-shot CloudFormation command.
#

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

source "${SHARED_DIR}/init-fn.sh" || true

function save_stack_events_to_artifacts() {
  echo "## exit handler / saving stack events ##"
  set +o errexit
  while read -r stack_name
  do
    aws --region "${AWS_REGION}" cloudformation describe-stack-events --stack-name ${stack_name} --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"
  done < "${NEW_STACKS-}"
  set -o errexit
}
#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  log "Failed to acquire lease"
  exit 1
fi
AWS_REGION=${LEASED_RESOURCE}
export AWS_DEFAULT_REGION="${AWS_REGION}"  # CLI prefers the former
export PATH=/tmp:${PATH}

echo "======================="
echo "Installing dependencies"
echo "======================="

install_jq
install_yq3
install_awscli

echo "==============================="
echo "Patch CloudFormation Templates"
echo "==============================="

TEMPLATES_BASE=https://raw.githubusercontent.com/openshift-splat-team/installer-labs
TEMPLATES_VERSION=main
TEMPLATES_PATH=installer-upi/aws/cloudformation/templates

TEMPLATE_URL=${TEMPLATES_BASE}/${TEMPLATES_VERSION}/${TEMPLATES_PATH}
TEMPLATES=( "01_vpc.yaml" )
TEMPLATES+=( "02_cluster_infra.yaml" )
TEMPLATES+=( "03_cluster_security.yaml" )
TEMPLATES+=( "04_cluster_bootstrap.yaml" )
TEMPLATES+=( "05_cluster_master_nodes.yaml" )
TEMPLATES+=( "06_cluster_worker_node.yaml" )

#TEMPLTE_DEST="/var/lib/upi-installer/${TEMPLATES_PATH}"
TEMPLTE_DEST="/tmp"

for TEMPLATE in "${TEMPLATES[@]}"; do
  log "Updating ${TEMPLATE}"
  curl -sL "${TEMPLATE_URL}/${TEMPLATE}" > "${TEMPLTE_DEST}/${TEMPLATE}"
done

echo "================================="
echo "CREATING INFRASTRUCTURE RESOURCES"
echo "================================="

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.

GATHER_BOOTSTRAP_ARGS=
NEW_STACKS="${SHARED_DIR}/aws_cfn_stacks"
touch $NEW_STACKS

function add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

export OPENSHIFT_INSTALL_INVOKER
export AWS_SHARED_CREDENTIALS_FILE
export EXPIRATION_DATE

base_domain=$(yq3 r "${SHARED_DIR}/install-config.yaml" 'baseDomain')
CLUSTER_NAME=$(yq3 r "${SHARED_DIR}/install-config.yaml" 'metadata.name')

echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME

RHCOS_AMI=$(<"${SHARED_DIR}"/image_id.txt)
INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"
IGNITION_CA="$(jq '.ignition.security.tls.certificateAuthorities[0].source' ${SHARED_DIR}/master.ign)"  # explicitly keeping wrapping quotes

HOSTED_ZONE="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${base_domain}" \
  --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
  --output text)"

if [[ -z "${HOSTED_ZONE}" ]]; then
  log "Hosted zone not found"
  exit 1
fi

# Define Stack names
VPC_STACK_NAME=${CLUSTER_NAME}-vpc
INFRA_STACK_NAME=${CLUSTER_NAME}-infra
SECURITY_STACK_NAME=${CLUSTER_NAME}-security
BOOTSTRAP_STACK_NAME=${CLUSTER_NAME}-bootstrap
CONTROL_PLANE_STACK_NAME=${CLUSTER_NAME}-control-plane
COMPUTE_STACK_NAME_PREFIX=${CLUSTER_NAME}-compute

# Create s3 bucket for bootstrap and proxy ignition configs
aws s3 mb s3://"${INFRA_STACK_NAME}"

echo "==================="
echo "CREATING STACK: VPC"
echo "==================="

log "Creating VPC Stack..."

# If we are using a proxy, create a 'black-hole' private subnet vpc TODO
# For now this is just a placeholder...
cf_params_vpc=${ARTIFACT_DIR}/cf_params_vpc.json
add_param_to_json AvailabilityZoneCount 2 "${cf_params_vpc}"
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_vpc}"

cat "${cf_params_vpc}"

echo "${VPC_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack  --stack-name "${VPC_STACK_NAME}" \
  --template-body "$(cat "${TEMPLTE_DEST}/01_vpc.yaml")" \
  --tags "${TAGS}" \
  --parameters "file://${cf_params_vpc}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${VPC_STACK_NAME}" &
wait "$!"

VPC_JSON="$(aws cloudformation describe-stacks --stack-name "${VPC_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
VPC_ID="$(echo "${VPC_JSON}" | jq -r '.[] | select(.OutputKey == "VpcId").OutputValue')"
PRIVATE_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PrivateSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes
PRIVATE_SUBNET_0="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f1)"
PRIVATE_SUBNET_1="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f2)"
# PRIVATE_SUBNET_2="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f3)"
PRIVATE_SUBNET_2="$PRIVATE_SUBNET_0"
PUBLIC_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PublicSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes

# Adapt step aws-provision-tags-for-byo-vpc, which is required by Ingress operator testing.
echo ${VPC_ID} > "${SHARED_DIR}/vpc_id"
echo ${VPC_JSON} | jq -c '[.[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[]]' | sed "s/\"/'/g" > "${SHARED_DIR}/private_subnet_ids"
echo ${VPC_JSON} | jq -c '[.[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[]]' | sed "s/\"/'/g" > "${SHARED_DIR}/public_subnet_ids"

echo "====================="
echo "CREATING STACK: INFRA"
echo "====================="

log "Creating Infra Stack..."

cf_params_infra=${ARTIFACT_DIR}/cf_params_infra.json
add_param_to_json ClusterName "${CLUSTER_NAME}" "${cf_params_infra}"
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_infra}"
add_param_to_json HostedZoneId "${HOSTED_ZONE}" "${cf_params_infra}"
add_param_to_json HostedZoneName "${base_domain}" "${cf_params_infra}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_infra}"
add_param_to_json PrivateSubnets "$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g')" "${cf_params_infra}"
add_param_to_json PublicSubnets "$(echo "${PUBLIC_SUBNETS}" | sed 's/"//g')" "${cf_params_infra}"

cat "${cf_params_infra}"

echo "${INFRA_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${INFRA_STACK_NAME}" \
  --template-body "$(cat "${TEMPLTE_DEST}/02_cluster_infra.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_infra} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${INFRA_STACK_NAME}" &
wait "$!"

INFRA_JSON="$(aws cloudformation describe-stacks --stack-name "${INFRA_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
NLB_IP_TARGETS_LAMBDA="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "RegisterNlbIpTargetsLambdaArn").OutputValue')"
EXTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "ExternalApiTargetGroupArn").OutputValue')"
INTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalApiTargetGroupArn").OutputValue')"
INTERNAL_SERVICE_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalServiceTargetGroupArn").OutputValue')"
INGRESS_HTTP_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "IngressHTTPTargetGroupArn").OutputValue')"
INGRESS_HTTPS_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "IngressHTTPSTargetGroupArn").OutputValue')"
PRIVATE_HOSTED_ZONE="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "PrivateHostedZoneId").OutputValue')"

echo "========================="
echo "CREATING STACK: SECURITY"
echo "========================="

log "Creating Security Stack..."

cf_params_security=${ARTIFACT_DIR}/cf_params_security.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_security}"
add_param_to_json VpcCidr "${MACHINE_CIDR}" "${cf_params_security}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_security}"
add_param_to_json PrivateSubnets "$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g')" "${cf_params_security}"

cat "${cf_params_security}"

echo "${SECURITY_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${SECURITY_STACK_NAME}" \
  --template-body "$(cat "${TEMPLTE_DEST}/03_cluster_security.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_security} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${SECURITY_STACK_NAME}" &
wait "$!"

SECURITY_JSON="$(aws cloudformation describe-stacks --stack-name "${SECURITY_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
MASTER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterSecurityGroupId").OutputValue')"
MASTER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterInstanceProfile").OutputValue')"
WORKER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerSecurityGroupId").OutputValue')"
WORKER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerInstanceProfile").OutputValue')"

S3_BOOTSTRAP_URI="s3://${INFRA_STACK_NAME}/bootstrap.ign"
aws s3 cp ${SHARED_DIR}/bootstrap.ign "$S3_BOOTSTRAP_URI"

echo "========================="
echo "CREATING STACK: BOOTSTRAP"
echo "========================="

log "Creating Boostrap Stack..."

cf_params_bootstrap=${ARTIFACT_DIR}/cf_params_bootstrap.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_bootstrap}"
add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_bootstrap}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_bootstrap}"
add_param_to_json PublicSubnet "$(echo ${PUBLIC_SUBNETS%%,*} | sed 's/"//g')" "${cf_params_bootstrap}"
add_param_to_json MasterSecurityGroupId "${MASTER_SECURITY_GROUP}" "${cf_params_bootstrap}"
add_param_to_json BootstrapIgnitionLocation "${S3_BOOTSTRAP_URI}" "${cf_params_bootstrap}"
add_param_to_json RegisterNlbIpTargetsLambdaArn "${NLB_IP_TARGETS_LAMBDA}" "${cf_params_bootstrap}"
add_param_to_json ExternalApiTargetGroupArn "${EXTERNAL_API_TARGET_GROUP}" "${cf_params_bootstrap}"
add_param_to_json InternalApiTargetGroupArn "${INTERNAL_API_TARGET_GROUP}" "${cf_params_bootstrap}"
add_param_to_json InternalServiceTargetGroupArn "${INTERNAL_SERVICE_TARGET_GROUP}" "${cf_params_bootstrap}"
add_param_to_json BootstrapInstanceType "${BOOTSTRAP_INSTANCE_TYPE}" "${cf_params_bootstrap}"

cat "${cf_params_bootstrap}"

echo "${BOOTSTRAP_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --template-body "$(cat "${TEMPLTE_DEST}/04_cluster_bootstrap.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_bootstrap} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

BOOTSTRAP_IP="$(aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `BootstrapPublicIp`].OutputValue' --output text)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_IP}"

echo "$BOOTSTRAP_STACK_NAME" > "${SHARED_DIR}"/STACK_NAME_BOOTSTRAP
echo "$BOOTSTRAP_IP" > "${SHARED_DIR}"/BOOTSTRAP_IP

echo "============================="
echo "CREATING STACK: CONTROL PLANE"
echo "============================="

log "Creating Control Plane Stack..."

cf_params_control_plane=${ARTIFACT_DIR}/cf_params_control_plane.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_control_plane}"
add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_control_plane}"
add_param_to_json PrivateHostedZoneId "${PRIVATE_HOSTED_ZONE}" "${cf_params_control_plane}"
add_param_to_json PrivateHostedZoneName "${CLUSTER_NAME}.${base_domain}" "${cf_params_control_plane}"
add_param_to_json Master0Subnet "${PRIVATE_SUBNET_0}" "${cf_params_control_plane}"
add_param_to_json Master1Subnet "${PRIVATE_SUBNET_1}" "${cf_params_control_plane}"
add_param_to_json Master2Subnet "${PRIVATE_SUBNET_2}" "${cf_params_control_plane}"
add_param_to_json MasterSecurityGroupId "${MASTER_SECURITY_GROUP}" "${cf_params_control_plane}"
add_param_to_json IgnitionLocation "https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/master" "${cf_params_control_plane}"
add_param_to_json CertificateAuthorities "$(echo ${IGNITION_CA} | sed 's/"//g')" "${cf_params_control_plane}"
add_param_to_json MasterInstanceProfileName "${MASTER_INSTANCE_PROFILE}" "${cf_params_control_plane}"
add_param_to_json RegisterNlbIpTargetsLambdaArn "${NLB_IP_TARGETS_LAMBDA}" "${cf_params_control_plane}"
add_param_to_json ExternalApiTargetGroupArn "${EXTERNAL_API_TARGET_GROUP}" "${cf_params_control_plane}"
add_param_to_json InternalApiTargetGroupArn "${INTERNAL_API_TARGET_GROUP}" "${cf_params_control_plane}"
add_param_to_json InternalServiceTargetGroupArn "${INTERNAL_SERVICE_TARGET_GROUP}" "${cf_params_control_plane}"
add_param_to_json MasterInstanceType "${MASTER_INSTANCE_TYPE}" "${cf_params_control_plane}"

cat "${cf_params_control_plane}"

echo "${CONTROL_PLANE_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${CONTROL_PLANE_STACK_NAME}" \
  --template-body "$(cat "${TEMPLTE_DEST}/05_cluster_master_nodes.yaml")" \
  --tags "${TAGS}" \
  --parameters file://${cf_params_control_plane} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CONTROL_PLANE_STACK_NAME}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CONTROL_PLANE_STACK_NAME}"
CONTROL_PLANE_IPS="$(aws cloudformation describe-stacks --stack-name "${CONTROL_PLANE_STACK_NAME}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIPs`].OutputValue' --output text)"
CONTROL_PLANE_0_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f1)"
CONTROL_PLANE_1_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f2)"
CONTROL_PLANE_2_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f3)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${CONTROL_PLANE_0_IP} --master ${CONTROL_PLANE_1_IP} --master ${CONTROL_PLANE_2_IP}"

echo "======================"
echo "CREATING STACK:WORKERS"
echo "======================"

log "Creating Worker Stack..."

for INDEX in 0 1 2
do
  SUBNET="PRIVATE_SUBNET_${INDEX}"
  COMPUTE_STACK_NAME=${COMPUTE_STACK_NAME_PREFIX}-${INDEX}

  cf_params_compute="${ARTIFACT_DIR}/cf_params_compute_${INDEX}.json"
  add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_compute}"
  add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_compute}"
  add_param_to_json Subnet "${!SUBNET}" "${cf_params_compute}"
  add_param_to_json WorkerSecurityGroupId "${WORKER_SECURITY_GROUP}" "${cf_params_compute}"
  add_param_to_json IgnitionLocation "https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/worker" "${cf_params_compute}"
  add_param_to_json CertificateAuthorities "$(echo ${IGNITION_CA} | sed 's/"//g')" "${cf_params_compute}"
  add_param_to_json WorkerInstanceType "${WORKER_INSTANCE_TYPE}" "${cf_params_compute}"
  add_param_to_json WorkerInstanceProfileName "${WORKER_INSTANCE_PROFILE}" "${cf_params_compute}"
  add_param_to_json RegisterNlbIpTargetsLambdaArn "${NLB_IP_TARGETS_LAMBDA}" "${cf_params_compute}"
  add_param_to_json IngressHTTPTargetGroupArn "${INGRESS_HTTP_TARGET_GROUP}" "${cf_params_compute}"
  add_param_to_json IngressHTTPSTargetGroupArn "${INGRESS_HTTPS_TARGET_GROUP}" "${cf_params_compute}"
  add_param_to_json NodeID "worker-${INDEX}" "${cf_params_compute}"

  cat "${cf_params_compute}"
  echo "${COMPUTE_STACK_NAME}" >> "${NEW_STACKS}"
  aws cloudformation create-stack \
    --stack-name "${COMPUTE_STACK_NAME}" \
    --template-body "$(cat "${TEMPLTE_DEST}/06_cluster_worker_node.yaml")" \
    --tags "${TAGS}" \
    --parameters file://${cf_params_compute} &
  wait "$!"

  aws cloudformation wait stack-create-complete --stack-name "${COMPUTE_STACK_NAME}" &
  wait "$!"

  COMPUTE_VAR="COMPUTE_${INDEX}_IP"
  COMPUTE_IP="$(aws cloudformation describe-stacks --stack-name "${COMPUTE_STACK_NAME}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIP`].OutputValue' --output text)"
  export COMPUTE_IP
  eval "${COMPUTE_VAR}=\${COMPUTE_IP}"
done

log "Install done!"
echo -e "bootstrap: ${BOOTSTRAP_IP}"
echo -e "control-plane: ${CONTROL_PLANE_0_IP} ${CONTROL_PLANE_1_IP} ${CONTROL_PLANE_2_IP}"
# shellcheck disable=SC2153
echo -e "compute: ${COMPUTE_0_IP} ${COMPUTE_1_IP} ${COMPUTE_2_IP}"

echo "${GATHER_BOOTSTRAP_ARGS}" > "${SHARED_DIR}"/GATHER_BOOTSTRAP_ARGS
