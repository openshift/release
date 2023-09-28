#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}
GATHER_BOOTSTRAP_ARGS=
NEW_STACKS=$(mktemp)

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
    openshift-install --dir=${ARTIFACT_DIR}/installer gather bootstrap --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  return 1
}

function save_stack_events_to_artifacts()
{
  set +o errexit
  while read -r stack_name
  do
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
mkdir ${ARTIFACT_DIR}/installer

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
cp ${SHARED_DIR}/install-config.yaml ${ARTIFACT_DIR}/installer/install-config.yaml
export PATH=${HOME}/.local/bin:${PATH}

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
echo "OCP Version: ${ocp_version}"
rm /tmp/pull-secret

pushd ${ARTIFACT_DIR}/installer

base_domain=$(yq-go r "${ARTIFACT_DIR}/installer/install-config.yaml" 'baseDomain')
AWS_REGION=$(yq-go r "${ARTIFACT_DIR}/installer/install-config.yaml" 'platform.aws.region')
CLUSTER_NAME=$(yq-go r "${ARTIFACT_DIR}/installer/install-config.yaml" 'metadata.name')

echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME
MACHINE_CIDR=10.0.0.0/16

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
openshift-install --dir=${ARTIFACT_DIR}/installer create manifests
sed -i '/^  channel:/d' ${ARTIFACT_DIR}/installer/manifests/cvo-overrides.yaml
rm -f ${ARTIFACT_DIR}/installer/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f ${ARTIFACT_DIR}/installer/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
rm -f ${ARTIFACT_DIR}/installer/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" ${ARTIFACT_DIR}/installer/manifests/cluster-scheduler-02-config.yml

echo "Creating ignition configs"
openshift-install --dir=${ARTIFACT_DIR}/installer create ignition-configs &
wait "$!"

cp ${ARTIFACT_DIR}/installer/bootstrap.ign ${SHARED_DIR}
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

INFRA_ID="$(jq -r .infraID ${ARTIFACT_DIR}/installer/metadata.json)"
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"
IGNITION_CA="$(jq '.ignition.security.tls.certificateAuthorities[0].source' ${ARTIFACT_DIR}/installer/master.ign)"  # explicitly keeping wrapping quotes

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
aws s3 mb s3://"${INFRA_STACK_NAME}"

# If we are using a proxy, create a 'black-hole' private subnet vpc TODO
# For now this is just a placeholder...
cf_params_vpc=${ARTIFACT_DIR}/cf_params_vpc.json
add_param_to_json AvailabilityZoneCount 3 "${cf_params_vpc}"
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

if [[ -d "${SHARED_DIR}/CA" ]]; then
  # host proxy ignition on s3
  S3_PROXY_URI="s3://${INFRA_STACK_NAME}/proxy.ign"
  aws s3 cp ${SHARED_DIR}/proxy.ign "$S3_PROXY_URI"

  PROXY_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/proxy.ign"
  export PROXY_URI

  echo "${PROXY_STACK_NAME}" >> "${NEW_STACKS}"
  aws cloudformation create-stack \
    --stack-name "${PROXY_STACK_NAME}" \
    --template-body "$(cat "${SHARED_DIR}/04_cluster_proxy.yaml")" \
    --tags "${TAGS}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
      ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
      ParameterKey=RhcosAmi,ParameterValue="${RHCOS_AMI}" \
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

  PROXY_IP="$(aws cloudformation describe-stacks --stack-name "${PROXY_STACK_NAME}" \
    --query 'Stacks[].Outputs[?OutputKey == `ProxyPublicIp`].OutputValue' --output text)"

  PROXY_URL=$(cat ${SHARED_DIR}/PROXY_URL)
  TLS_PROXY_URL=$(cat ${SHARED_DIR}/TLS_PROXY_URL)

  echo "Proxy is available at ${PROXY_URL}"
  echo "TLS Proxy is available at ${TLS_PROXY_URL}"

  echo ${PROXY_IP} > ${ARTIFACT_DIR}/installer/proxyip
fi

S3_BOOTSTRAP_URI="s3://${INFRA_STACK_NAME}/bootstrap.ign"
aws s3 cp ${ARTIFACT_DIR}/installer/bootstrap.ign "$S3_BOOTSTRAP_URI"

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
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

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
export KUBECONFIG=${ARTIFACT_DIR}/installer/auth/kubeconfig
approve_csrs &

set +x
echo "Completing UPI setup"
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' ${ARTIFACT_DIR}/installer/.openshift_install.log
# The image registry in some instances the config object
# is not properly configured. Rerun patching
# after cluster complete
cp "${ARTIFACT_DIR}/installer/metadata.json" "${SHARED_DIR}/"
cp "${ARTIFACT_DIR}/installer/auth/kubeconfig" "${SHARED_DIR}/"
cp "${ARTIFACT_DIR}/installer/auth/kubeadmin-password" "${SHARED_DIR}/"
touch /tmp/install-complete
