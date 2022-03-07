#!/bin/bash
set -euo pipefail

INSTALL_STAGE="initial"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save install status for must-gather to generate junit
trap 'echo "$? $INSTALL_STAGE" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}
GATHER_BOOTSTRAP_ARGS=

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${ARTIFACT_DIR}/installer gather bootstrap --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  return 1
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

pushd ${ARTIFACT_DIR}/installer

base_domain=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["baseDomain"])')
AWS_REGION=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["platform"]["aws"]["region"])')
CLUSTER_NAME=$(python3 -c 'import yaml;data = yaml.full_load(open("install-config.yaml"));print(data["metadata"]["name"])')
echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME
MACHINE_CIDR=10.0.0.0/16

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
openshift-install --dir=${ARTIFACT_DIR}/installer create manifests
sed -i '/^  channel:/d' ${ARTIFACT_DIR}/installer/manifests/cvo-overrides.yaml
rm -f ${ARTIFACT_DIR}/installer/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f ${ARTIFACT_DIR}/installer/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
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
  if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
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

# Create s3 bucket for bootstrap and proxy ignition configs
aws s3 mb s3://"${CLUSTER_NAME}-infra"

# If we are using a proxy, create a 'black-hole' private subnet vpc TODO
# For now this is just a placeholder...
aws cloudformation create-stack  --stack-name "${CLUSTER_NAME}-vpc" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/01_vpc.yaml")" \
  --tags "${TAGS}" \
  --parameters \
    ParameterKey=AvailabilityZoneCount,ParameterValue=3 &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-vpc" &
wait "$!"

VPC_JSON="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-vpc" \
  --query 'Stacks[].Outputs[]' --output json)"
VPC_ID="$(echo "${VPC_JSON}" | jq -r '.[] | select(.OutputKey == "VpcId").OutputValue')"
PRIVATE_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PrivateSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes
PRIVATE_SUBNET_0="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f1)"
PRIVATE_SUBNET_1="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f2)"
PRIVATE_SUBNET_2="$(echo "${PRIVATE_SUBNETS}" | sed 's/"//g' | cut -d, -f3)"
PUBLIC_SUBNETS="$(echo "${VPC_JSON}" | jq '.[] | select(.OutputKey == "PublicSubnetIds").OutputValue')"  # explicitly keeping wrapping quotes

aws cloudformation create-stack \
  --stack-name "${CLUSTER_NAME}-infra" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/02_cluster_infra.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}" \
    ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
    ParameterKey=HostedZoneId,ParameterValue="${HOSTED_ZONE}" \
    ParameterKey=HostedZoneName,ParameterValue="${base_domain}" \
    ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
    ParameterKey=PrivateSubnets,ParameterValue="${PRIVATE_SUBNETS}" \
    ParameterKey=PublicSubnets,ParameterValue="${PUBLIC_SUBNETS}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-infra" &
wait "$!"

INFRA_JSON="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-infra" \
  --query 'Stacks[].Outputs[]' --output json)"
NLB_IP_TARGETS_LAMBDA="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "RegisterNlbIpTargetsLambda").OutputValue')"
EXTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "ExternalApiTargetGroupArn").OutputValue')"
INTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalApiTargetGroupArn").OutputValue')"
INTERNAL_SERVICE_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalServiceTargetGroupArn").OutputValue')"
PRIVATE_HOSTED_ZONE="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "PrivateHostedZoneId").OutputValue')"

aws cloudformation create-stack \
  --stack-name "${CLUSTER_NAME}-security" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/03_cluster_security.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
    ParameterKey=VpcCidr,ParameterValue="${MACHINE_CIDR}" \
    ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
    ParameterKey=PrivateSubnets,ParameterValue="${PRIVATE_SUBNETS}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-security" &
wait "$!"

SECURITY_JSON="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-security" \
  --query 'Stacks[].Outputs[]' --output json)"
MASTER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterSecurityGroupId").OutputValue')"
MASTER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterInstanceProfile").OutputValue')"
WORKER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerSecurityGroupId").OutputValue')"
WORKER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerInstanceProfile").OutputValue')"

if [[ -d "${SHARED_DIR}/CA" ]]; then
  # host proxy ignition on s3
  S3_PROXY_URI="s3://${CLUSTER_NAME}-infra/proxy.ign"
  aws s3 cp ${SHARED_DIR}/proxy.ign "$S3_PROXY_URI"

  PROXY_URI="https://${JOB_NAME_SAFE}-bootstrap-exporter-${NAMESPACE}.svc.ci.openshift.org/proxy.ign"
  export PROXY_URI

  aws cloudformation create-stack \
    --stack-name "${CLUSTER_NAME}-proxy" \
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

  aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-proxy" &
  wait "$!"

  PROXY_IP="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-proxy" \
    --query 'Stacks[].Outputs[?OutputKey == `ProxyPublicIp`].OutputValue' --output text)"

  PROXY_URL=$(cat ${SHARED_DIR}/PROXY_URL)
  TLS_PROXY_URL=$(cat ${SHARED_DIR}/TLS_PROXY_URL)

  echo "Proxy is available at ${PROXY_URL}"
  echo "TLS Proxy is available at ${TLS_PROXY_URL}"

  echo ${PROXY_IP} > ${ARTIFACT_DIR}/installer/proxyip
fi

S3_BOOTSTRAP_URI="s3://${CLUSTER_NAME}-infra/bootstrap.ign"
aws s3 cp ${ARTIFACT_DIR}/installer/bootstrap.ign "$S3_BOOTSTRAP_URI"

aws cloudformation create-stack \
  --stack-name "${CLUSTER_NAME}-bootstrap" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/04_cluster_bootstrap.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
    ParameterKey=RhcosAmi,ParameterValue="${RHCOS_AMI}" \
    ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
    ParameterKey=PublicSubnet,ParameterValue="${PUBLIC_SUBNETS%%,*}\"" \
    ParameterKey=MasterSecurityGroupId,ParameterValue="${MASTER_SECURITY_GROUP}" \
    ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
    ParameterKey=BootstrapIgnitionLocation,ParameterValue="${S3_BOOTSTRAP_URI}" \
    ParameterKey=RegisterNlbIpTargetsLambdaArn,ParameterValue="${NLB_IP_TARGETS_LAMBDA}" \
    ParameterKey=ExternalApiTargetGroupArn,ParameterValue="${EXTERNAL_API_TARGET_GROUP}" \
    ParameterKey=InternalApiTargetGroupArn,ParameterValue="${INTERNAL_API_TARGET_GROUP}" \
    ParameterKey=InternalServiceTargetGroupArn,ParameterValue="${INTERNAL_SERVICE_TARGET_GROUP}" \
    ParameterKey=BootstrapInstanceType,ParameterValue="${BOOTSTRAP_INSTANCE_TYPE}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-bootstrap" &
wait "$!"

BOOTSTRAP_IP="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-bootstrap" \
  --query 'Stacks[].Outputs[?OutputKey == `BootstrapPublicIp`].OutputValue' --output text)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_IP}"

aws cloudformation create-stack \
  --stack-name "${CLUSTER_NAME}-control-plane" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/05_cluster_master_nodes.yaml")" \
  --tags "${TAGS}" \
  --parameters \
    ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
    ParameterKey=RhcosAmi,ParameterValue="${RHCOS_AMI}" \
    ParameterKey=PrivateHostedZoneId,ParameterValue="${PRIVATE_HOSTED_ZONE}" \
    ParameterKey=PrivateHostedZoneName,ParameterValue="${CLUSTER_NAME}.${base_domain}" \
    ParameterKey=Master0Subnet,ParameterValue="${PRIVATE_SUBNET_0}" \
    ParameterKey=Master1Subnet,ParameterValue="${PRIVATE_SUBNET_1}" \
    ParameterKey=Master2Subnet,ParameterValue="${PRIVATE_SUBNET_2}" \
    ParameterKey=MasterSecurityGroupId,ParameterValue="${MASTER_SECURITY_GROUP}" \
    ParameterKey=IgnitionLocation,ParameterValue="https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/master" \
    ParameterKey=CertificateAuthorities,ParameterValue="${IGNITION_CA}" \
    ParameterKey=MasterInstanceProfileName,ParameterValue="${MASTER_INSTANCE_PROFILE}" \
    ParameterKey=RegisterNlbIpTargetsLambdaArn,ParameterValue="${NLB_IP_TARGETS_LAMBDA}" \
    ParameterKey=ExternalApiTargetGroupArn,ParameterValue="${EXTERNAL_API_TARGET_GROUP}" \
    ParameterKey=InternalApiTargetGroupArn,ParameterValue="${INTERNAL_API_TARGET_GROUP}" \
    ParameterKey=InternalServiceTargetGroupArn,ParameterValue="${INTERNAL_SERVICE_TARGET_GROUP}" \
    ParameterKey=MasterInstanceType,ParameterValue="${MASTER_INSTANCE_TYPE}" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-control-plane" &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-control-plane"
CONTROL_PLANE_IPS="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-control-plane" --query 'Stacks[].Outputs[?OutputKey == `PrivateIPs`].OutputValue' --output text)"
CONTROL_PLANE_0_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f1)"
CONTROL_PLANE_1_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f2)"
CONTROL_PLANE_2_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f3)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${CONTROL_PLANE_0_IP} --master ${CONTROL_PLANE_1_IP} --master ${CONTROL_PLANE_2_IP}"

for INDEX in 0 1 2
do
  SUBNET="PRIVATE_SUBNET_${INDEX}"
  aws cloudformation create-stack \
    --stack-name "${CLUSTER_NAME}-compute-${INDEX}" \
    --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/06_cluster_worker_node.yaml")" \
    --tags "${TAGS}" \
    --parameters \
      ParameterKey=InfrastructureName,ParameterValue="${INFRA_ID}" \
      ParameterKey=RhcosAmi,ParameterValue="${RHCOS_AMI}" \
      ParameterKey=Subnet,ParameterValue="${!SUBNET}" \
      ParameterKey=WorkerSecurityGroupId,ParameterValue="${WORKER_SECURITY_GROUP}" \
      ParameterKey=IgnitionLocation,ParameterValue="https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/worker" \
      ParameterKey=CertificateAuthorities,ParameterValue="${IGNITION_CA}" \
      ParameterKey=WorkerInstanceType,ParameterValue="${WORKER_INSTANCE_TYPE}" \
      ParameterKey=WorkerInstanceProfileName,ParameterValue="${WORKER_INSTANCE_PROFILE}" &
  wait "$!"

  aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}-compute-${INDEX}" &
  wait "$!"

  COMPUTE_VAR="COMPUTE_${INDEX}_IP"
  COMPUTE_IP="$(aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-compute-${INDEX}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIP`].OutputValue' --output text)"
  export COMPUTE_IP
  eval "${COMPUTE_VAR}=\${COMPUTE_IP}"
done

# shellcheck disable=SC2153
echo "bootstrap: ${BOOTSTRAP_IP} control-plane: ${CONTROL_PLANE_0_IP} ${CONTROL_PLANE_1_IP} ${CONTROL_PLANE_2_IP} compute: ${COMPUTE_0_IP} ${COMPUTE_1_IP} ${COMPUTE_2_IP}"

echo "Waiting for bootstrap to complete"
openshift-install --dir=${ARTIFACT_DIR}/installer wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

INSTALL_STAGE="bootstrap_successful"
echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${CLUSTER_NAME}-bootstrap" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER_NAME}-bootstrap" &
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

INSTALL_STAGE="cluster_creation_successful"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' ${ARTIFACT_DIR}/installer/.openshift_install.log
# The image registry in some instances the config object
# is not properly configured. Rerun patching
# after cluster complete
cp "${ARTIFACT_DIR}/installer/metadata.json" "${SHARED_DIR}/"
cp "${ARTIFACT_DIR}/installer/auth/kubeconfig" "${SHARED_DIR}"
touch /tmp/install-complete