#!/bin/bash
set -euo pipefail

teardown() {
    local exit_code=$?

    #Save exit code for must-gather to generate junit
    echo "$exit_code" > "${SHARED_DIR}/install-status.txt"

    #Save stacks events for debugging
    save_stack_events_to_artifacts

    prepare_next_steps

    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null

    exit $exit_code
}

trap teardown EXIT
trap 'exit 130' INT   # 130 = 128 + 2 (SIGINT)
trap 'exit 143' TERM  # 143 = 128 + 15 (SIGTERM)

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}
GATHER_BOOTSTRAP_ARGS=
NEW_STACKS=$(mktemp)

INSTALL_DIR=/tmp/installer
mkdir ${INSTALL_DIR}

function populate_artifact_dir()
{
  set +e
  current_time=$(date +%s)

  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # terraform may not exist now
  if [ -f "${INSTALL_DIR}/terraform.txt" ]; then
    sed -i '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${INSTALL_DIR}/terraform.txt"
    tar -czvf "${ARTIFACT_DIR}/terraform-${current_time}.tar.gz" --remove-files "${INSTALL_DIR}/terraform.txt"
  fi

  # Copy CAPI-generated artifacts if they exist
  if [ -d "${INSTALL_DIR}/.clusterapi_output" ]; then
    echo "Copying Cluster API generated manifests..."
    mkdir -p "${ARTIFACT_DIR}/clusterapi_output-${current_time}"
    cp -rpv "${INSTALL_DIR}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output-${current_time}" 2>/dev/null
  fi
  set -e
}

function prepare_next_steps() {
  set +e
  populate_artifact_dir

  echo "Copying required artifacts to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"
  set -e
}

function add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${INSTALL_DIR} gather bootstrap --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  if [[ -n "${PROXY_INSTANCE_ID}" ]]; then
    aws ec2 get-console-output --instance-id ${PROXY_INSTANCE_ID} --output text > "${ARTIFACT_DIR}/proxy-instance-console-output.log" || true
  fi

  return 1
}

function save_stack_events_to_artifacts()
{
  set +o errexit
  echo "saving stack events to artifacts dir..."
  while read -r stack_name
  do
    echo "processing $stack_name ..."
    aws --region ${AWS_REGION} cloudformation describe-stack-events --stack-name ${stack_name} --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"
  done < "${NEW_STACKS}"
  set -o errexit
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

cp "$(command -v openshift-install)" /tmp

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
PULL_SECRET=${CLUSTER_PROFILE_DIR}/pull-secret

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
export PULL_SECRET_PATH
export OPENSHIFT_INSTALL_INVOKER
export AWS_SHARED_CREDENTIALS_FILE
export EXPIRATION_DATE
export PULL_SECRET

mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/
cp ${SHARED_DIR}/install-config.yaml ${INSTALL_DIR}/install-config.yaml
export PATH=${HOME}/.local/bin:${PATH}

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
echo "OCP Version: ${ocp_version}"
rm /tmp/pull-secret

pushd ${INSTALL_DIR}

base_domain=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'baseDomain')
AWS_REGION=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'platform.aws.region')
CLUSTER_NAME=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'metadata.name')

echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME
MACHINE_CIDR=10.0.0.0/16


echo "install-config.yaml"
echo "-------------------"
# hide proxy credential and some other sensitive info
cat ${SHARED_DIR}/install-config.yaml | sed -E 's#(https?://[^:@/]+):[^:@/]+@#\1:XXX@#g' | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml


date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
openshift-install --dir=${INSTALL_DIR} create manifests
sed -i '/^  channel:/d' ${INSTALL_DIR}/manifests/cvo-overrides.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" ${INSTALL_DIR}/manifests/cluster-scheduler-02-config.yml

echo "Creating ignition configs"
openshift-install --dir=${INSTALL_DIR} create ignition-configs &
wait "$!"

cp ${INSTALL_DIR}/bootstrap.ign ${SHARED_DIR}
BOOTSTRAP_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/bootstrap.ign"
export BOOTSTRAP_URI

# begin bootstrapping
if openshift-install coreos print-stream-json 2>/tmp/err.txt >coreos.json; then
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' coreos.json)"
  if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]] || [[ "${OCP_ARCH}" == "arm64" ]]; then
    RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.aarch64.images.aws.regions[$region].image' coreos.json)"
  fi
else
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.amis[$region].hvm' /var/lib/openshift-install/rhcos.json)"
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"  # CLI prefers the former

INFRA_ID="$(jq -r .infraID ${INSTALL_DIR}/metadata.json)"
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"
IGNITION_CA="$(jq '.ignition.security.tls.certificateAuthorities[0].source' ${INSTALL_DIR}/master.ign)"  # explicitly keeping wrapping quotes

HOSTED_ZONE="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${base_domain}" \
  --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
  --output text)"

# Define Stack names
VPC_STACK_NAME=${CLUSTER_NAME}-vpc
INFRA_STACK_NAME=${CLUSTER_NAME}-infra
SECURITY_STACK_NAME=${CLUSTER_NAME}-security
PROXY_STACK_NAME=${CLUSTER_NAME}-proxy
BOOTSTRAP_STACK_NAME=${CLUSTER_NAME}-bootstrap
CONTROL_PLANE_STACK_NAME=${CLUSTER_NAME}-control-plane
COMPUTE_STACK_NAME_PREFIX=${CLUSTER_NAME}-compute

# Create s3 bucket for bootstrap and proxy ignition configs
S3_BUCKET_URI="s3://${INFRA_STACK_NAME}"
aws s3 mb "${S3_BUCKET_URI}"
echo ${S3_BUCKET_URI} > ${SHARED_DIR}/s3_bucket_uri

# If we are using a proxy, create a 'black-hole' private subnet vpc TODO
# For now this is just a placeholder...
ZONES_COUNT=3
MAX_ZONES_COUNT=$(aws ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq '.AvailabilityZones | length')
if (( ZONES_COUNT > MAX_ZONES_COUNT )); then
  ZONES_COUNT=$MAX_ZONES_COUNT
fi

cf_params_vpc=${ARTIFACT_DIR}/cf_params_vpc.json
add_param_to_json AvailabilityZoneCount "${ZONES_COUNT}" "${cf_params_vpc}"
cat "${cf_params_vpc}"

echo "${VPC_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack  --stack-name "${VPC_STACK_NAME}" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/01_vpc.yaml")" \
  --tags "${TAGS}" \
  --parameters file://${cf_params_vpc} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${VPC_STACK_NAME}" &
wait "$!"

VPC_JSON="$(aws cloudformation describe-stacks --stack-name "${VPC_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
VPC_ID="$(echo "${VPC_JSON}" | jq -r '.[] | select(.OutputKey == "VpcId").OutputValue')"
PRIVATE_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PrivateSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes
PRIVATE_SUBNET_0="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f1)"
PRIVATE_SUBNET_1="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f2)"
PRIVATE_SUBNET_2="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f3)"
# when available zone < 3, some subnets would not be created, in that cases, always use the 1st subnet
if [[ -z "$PRIVATE_SUBNET_1" ]]; then
    PRIVATE_SUBNET_1=${PRIVATE_SUBNET_0}
fi
if [[ -z "$PRIVATE_SUBNET_2" ]]; then
    PRIVATE_SUBNET_2=${PRIVATE_SUBNET_0}
fi
PUBLIC_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PublicSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes

# Adapt step aws-provision-tags-for-byo-vpc, which is required by Ingress operator testing.
echo ${VPC_ID} > "${SHARED_DIR}/vpc_id"
echo ${VPC_JSON} | jq -c '[.[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[]]' | sed "s/\"/'/g" > "${SHARED_DIR}/private_subnet_ids"
echo ${VPC_JSON} | jq -c '[.[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[]]' | sed "s/\"/'/g" > "${SHARED_DIR}/public_subnet_ids"

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
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/02_cluster_infra.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_infra} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${INFRA_STACK_NAME}" &
wait "$!"

INFRA_JSON="$(aws cloudformation describe-stacks --stack-name "${INFRA_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
NLB_IP_TARGETS_LAMBDA="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "RegisterNlbIpTargetsLambda").OutputValue')"
EXTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "ExternalApiTargetGroupArn").OutputValue')"
INTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalApiTargetGroupArn").OutputValue')"
INTERNAL_SERVICE_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalServiceTargetGroupArn").OutputValue')"
PRIVATE_HOSTED_ZONE="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "PrivateHostedZoneId").OutputValue')"

cf_params_security=${ARTIFACT_DIR}/cf_params_security.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_security}"
add_param_to_json VpcCidr "${MACHINE_CIDR}" "${cf_params_security}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_security}"
add_param_to_json PrivateSubnets "$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g')" "${cf_params_security}"

cat "${cf_params_security}"

echo "${SECURITY_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${SECURITY_STACK_NAME}" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/03_cluster_security.yaml")" \
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

export PROXY_INSTANCE_ID=""
if [[ -f "${SHARED_DIR}/proxy.ign" ]] && [[ -f "${SHARED_DIR}/04_cluster_proxy.yaml" ]]; then
  # host proxy ignition on s3
  S3_PROXY_URI="${S3_BUCKET_URI}/proxy.ign"
  aws s3 cp ${SHARED_DIR}/proxy.ign "$S3_PROXY_URI"

  PROXY_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/proxy.ign"
  export PROXY_URI

  # To launch proxy server stably without ignition and ami compatibility issue, use a fixed version of coreos image + workable ignition in instance user data
  # E.g:
  # 4.18 AMI + 2.1.0 ignition would lead instance bootup faild with "failed to fetch config: unsupported config version"
  # so using 4.18 AMI + 3.0.0 ignition
  #bastion_image_list_url="https://builds.coreos.fedoraproject.org/streams/stable.json"
  bastion_image_list_url="https://raw.githubusercontent.com/openshift/installer/release-4.18/data/data/coreos/rhcos.json"
  if ! curl -sSLf --retry 3 --connect-timeout 30 --max-time 60 -o /tmp/bastion-image.json "${bastion_image_list_url}"; then
      echo "ERROR: Failed to download RHCOS image list from ${bastion_image_list_url}" >&2
      exit 1
  fi
  if ! jq empty /tmp/bastion-image.json &>/dev/null; then
      echo "ERROR: Downloaded file is not valid JSON" >&2
      exit 1
  fi
  ami_id=$(jq -r --arg r ${AWS_REGION} '.architectures.x86_64.images.aws.regions[$r].image // ""' /tmp/bastion-image.json)
  if [[ ${ami_id} == "" ]]; then
      echo "Bastion host AMI was NOT found in region ${AWS_REGION}, exit now." && exit 1
  fi

  echo -e "Proxy AMI ID in ${AWS_REGION}: $ami_id"

  echo "${PROXY_STACK_NAME}" >> "${NEW_STACKS}"
  aws cloudformation create-stack \
    --stack-name "${PROXY_STACK_NAME}" \
    --template-body "$(cat "${SHARED_DIR}/04_cluster_proxy.yaml")" \
    --tags "${TAGS}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
      ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
      ParameterKey=RhcosAmi,ParameterValue="${ami_id}" \
      ParameterKey=PrivateHostedZoneId,ParameterValue="${PRIVATE_HOSTED_ZONE}" \
      ParameterKey=PrivateHostedZoneName,ParameterValue="${CLUSTER_NAME}.${base_domain}" \
      ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}" \
      ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
      ParameterKey=PublicSubnet,ParameterValue="${PUBLIC_SUBNETS%%,*}\"" \
      ParameterKey=MasterSecurityGroupId,ParameterValue="${MASTER_SECURITY_GROUP}" \
      ParameterKey=ProxyIgnitionLocation,ParameterValue="${S3_PROXY_URI}" \
      ParameterKey=PrivateSubnets,ParameterValue="${PRIVATE_SUBNETS}" \
      ParameterKey=RegisterNlbIpTargetsLambdaArn,ParameterValue="${NLB_IP_TARGETS_LAMBDA}" \
      ParameterKey=ExternalApiTargetGroupArn,ParameterValue="${EXTERNAL_API_TARGET_GROUP}" \
      ParameterKey=InternalApiTargetGroupArn,ParameterValue="${INTERNAL_API_TARGET_GROUP}" \
      ParameterKey=InternalServiceTargetGroupArn,ParameterValue="${INTERNAL_SERVICE_TARGET_GROUP}" &
  wait "$!"

  aws cloudformation wait stack-create-complete --stack-name "${PROXY_STACK_NAME}" &
  wait "$!"

  PROXY_INSTANCE_ID="$(aws cloudformation describe-stacks --stack-name "${PROXY_STACK_NAME}" \
    --query 'Stacks[].Outputs[?OutputKey == `ProxyInstanceId`].OutputValue' --output text)"
  echo "Instance ${PROXY_INSTANCE_ID}"

  PROXY_IP="$(aws cloudformation describe-stacks --stack-name "${PROXY_STACK_NAME}" \
    --query 'Stacks[].Outputs[?OutputKey == `ProxyPublicIp`].OutputValue' --output text)"

  echo "Proxy is saved in ${SHARED_DIR}/http_proxy_url"
  echo "TLS Proxy is saved in ${SHARED_DIR}/https_proxy_url"

  echo ${PROXY_IP} > ${INSTALL_DIR}/proxyip
fi

S3_BOOTSTRAP_URI="${S3_BUCKET_URI}/bootstrap.ign"
aws s3 cp ${INSTALL_DIR}/bootstrap.ign "$S3_BOOTSTRAP_URI"

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

# For OCP <= 4.9, there is no BootstrapInstanceType param in UPI template
if (( ocp_minor_version >= 10 && ocp_major_version >= 4 )); then
  add_param_to_json BootstrapInstanceType "${BOOTSTRAP_INSTANCE_TYPE}" "${cf_params_bootstrap}"
fi


cat "${cf_params_bootstrap}"

echo "${BOOTSTRAP_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/04_cluster_bootstrap.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_bootstrap} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

BOOTSTRAP_IP="$(aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `BootstrapPublicIp`].OutputValue' --output text)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_IP}"

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
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/05_cluster_master_nodes.yaml")" \
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
  

  cat "${cf_params_compute}"
  echo "${COMPUTE_STACK_NAME}" >> "${NEW_STACKS}"
  aws cloudformation create-stack \
    --stack-name "${COMPUTE_STACK_NAME}" \
    --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/06_cluster_worker_node.yaml")" \
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

# shellcheck disable=SC2153
echo "bootstrap: ${BOOTSTRAP_IP} control-plane: ${CONTROL_PLANE_0_IP} ${CONTROL_PLANE_1_IP} ${CONTROL_PLANE_2_IP} compute: ${COMPUTE_0_IP} ${COMPUTE_1_IP} ${COMPUTE_2_IP}"

echo "Waiting for bootstrap to complete"
openshift-install --dir=${INSTALL_DIR} wait-for bootstrap-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

sed -i "/^${BOOTSTRAP_STACK_NAME}$/d" "$NEW_STACKS"

function approve_csrs() {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

function update_image_registry() {
  while true; do
    sleep 10;
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
  done
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
}

echo "Approving pending CSRs"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
approve_csrs &

set +x
echo "Completing UPI setup"
openshift-install --dir=${INSTALL_DIR} wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

touch /tmp/install-complete
