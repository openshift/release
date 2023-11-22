#!/bin/bash


set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'metadata.name')"
BASE_DOMAIN="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'baseDomain')"

which openshift-install
openshift-install version

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
  sed -i '
    s/password: .*/password: REDACTED/;
	s/X-Auth-Token.*/X-Auth-Token REDACTED/;
	s/UserData:.*,/UserData: REDACTED,/;
	' "${dir}/terraform.txt"
  tar -czvf "${ARTIFACT_DIR}/terraform.tar.gz" --remove-files "${dir}/terraform.txt"
}

function prepare_next_steps() {
  #Save exit code for must-gather to generate junit
  echo "$?" > "${SHARED_DIR}/install-status.txt"
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
  
  # For private cluster, the bootstrap address is private, installer cann't gather log-bundle directly even if proxy is set
  # the workaround is gather log-bundle from bastion host
  # copying install folder to bastion host for gathering logs
  publish=$(grep "publish:" ${SHARED_DIR}/install-config.yaml | awk '{print $2}')
  if [[ "${publish}" == "Internal" ]] && [[ ! $(grep "Bootstrap status: complete" "${dir}/.openshift_install.log") ]]; then
    echo "Copying install dir to bastion host."
    echo > "${SHARED_DIR}/REQUIRE_INSTALL_DIR_TO_BASTION"
    if [[ -s "${SHARED_DIR}/bastion_ssh_user" ]] && [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
      bastion_ssh_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
      bastion_public_address=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
      if [[ -n "${bastion_ssh_user}" ]] && [[ -n "${bastion_public_address}" ]]; then

        # Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
        # to be able to SSH.
        if ! whoami &> /dev/null; then
          if [[ -w /etc/passwd ]]; then
            echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
          else
            echo "/etc/passwd is not writeable, and user matching this uid is not found."
            exit 1
          fi
        fi

        cmd="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${CLUSTER_PROFILE_DIR}/ssh-privatekey\" -r ${dir} ${bastion_ssh_user}@${bastion_public_address}:/tmp/installer"
        echo "Running Command: ${cmd}"
        eval "${cmd}"
        echo > "${SHARED_DIR}/COPIED_INSTALL_DIR_TO_BASTION"
      else
        echo "ERROR: Can not get bastion user/host, skip to copy install dir."
      fi
    else
      echo "ERROR: File bastion_ssh_user or bastion_public_address is empty or not exist, skip to copy install dir."
    fi
  fi
}

function wait_router_lb_provision() {
    local try=0 retries=20
    local SERVICE
    SERVICE="$(oc -n openshift-ingress get service router-default -o json)"

    while test -z "$(echo "${SERVICE}" | jq -r '.status.loadBalancer.ingress[][]')" && test "${try}" -lt "${retries}"; do
      echo "waiting on router-default service load balancer ingress..."
      sleep 30
      SERVICE="$(oc -n openshift-ingress get service router-default -o json)"
      let try+=1
    done
    if [ "$try" -eq "$retries" ]; then
      echo "${SERVICE}"
      echo "ERROR: router-default service failed to provision load balancer ingress"
      return 1
    fi
    return 0
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
aws-c2s|aws-sc2s) export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_temp_creds;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac


# set CA_BUNDLE for C2S and SC2S 
if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  export AWS_CA_BUNDLE=${SHARED_DIR}/additional_trust_bundle
fi

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

echo "install-config.yaml"
echo "-------------------"
cat ${SHARED_DIR}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

# ---------------------------------------------------------
# manifests
# ---------------------------------------------------------
openshift-install --dir="${dir}" create manifests &
wait "$!"

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then
  yq-go d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.privateZone
  yq-go d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.publicZone
fi

if [ "${ENABLE_AWS_LOCALZONE}" == "yes" ]; then
  if [[ -f "${SHARED_DIR}/manifest_localzone_machineset.yaml" ]]; then
    # Phase 0, inject manifests
    
    # replace PLACEHOLDER_INFRA_ID PLACEHOLDER_AMI_ID
    echo "Local Zone is enabled, updating Infran ID and AMI ID ... "
    localzone_machineset="${SHARED_DIR}/manifest_localzone_machineset.yaml"
    infra_id=$(jq -r '."*installconfig.ClusterID".InfraID' "${dir}/.openshift_install_state.json")
    ami_id=$(grep ami "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" | tail -n1 | awk '{print$2}')
    sed -i "s/PLACEHOLDER_INFRA_ID/$infra_id/g" ${localzone_machineset}
    sed -i "s/PLACEHOLDER_AMI_ID/$ami_id/g" ${localzone_machineset}
    cp "${localzone_machineset}" "${ARTIFACT_DIR}/"
  else
    # Phase 1 & 2, use install-config
    if [[ "${LOCALZONE_WORKER_SCHEDULABLE}" == "yes" ]]; then
      echo 'LOCALZONE_WORKER_SCHEDULABLE is set to "yes", removing spec.template.spec.taints from localzone machineset'
      for local_zone_machineset in $(grep -lr 'cluster-api-machine-type: edge' ${dir});
      do
        echo "Removing spec.template.spec.taints from $(basename ${local_zone_machineset})"
        yq-go d "${local_zone_machineset}" spec.template.spec.taints
      done
    fi
  fi
  
fi

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

if [ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY:-}" == "true" ]; then
	echo "Cluster will be created with public subnets only"
fi

# ---------------------------------------------------------
# create cluster
# ---------------------------------------------------------

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
TF_LOG_PATH="${dir}/terraform.txt"
export TF_LOG_PATH

openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
set -e

if test "${ret}" -ne 0 ; then
  echo "Installation failed [create cluster]"
fi

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then

  export KUBECONFIG="${dir}/auth/kubeconfig"
  wait_router_lb_provision || exit 1

  if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
    # creating app record
    cat >> "/tmp/ingress_app.yml" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

Parameters:
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  RouterLbDns:
    Description: The loadbalancer DNS
    Type: String
  RouterLbHostedZoneId:
    Description: The Route53 zone ID where loadbalancer reside
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterLabels:
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      RouterLbDns:
        default: "router loadbalancer dns"
      RouterLbHostedZoneId:
        default: "Private Hosted Zone ID of router lb"

Resources:
  InternalAppsRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      AliasTarget:
        DNSName: !Ref RouterLbDns
        HostedZoneId: !Ref RouterLbHostedZoneId
        EvaluateTargetHealth: false
      HostedZoneId: !Ref PrivateHostedZoneId
      Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
      Type: A
EOF
  fi

  if [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
    # creating app record
    cat >> "/tmp/ingress_app.yml" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

Parameters:
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  RouterLbDns:
    Description: The loadbalancer DNS
    Type: String


Metadata:
  AWS::CloudFormation::Interface:
    ParameterLabels:
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      RouterLbDns:
        default: "router loadbalancer dns"

Resources:
  InternalAppsRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref PrivateHostedZoneId
      Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
      Type: CNAME
      TTL: 10
      ResourceRecords:
      - !Ref RouterLbDns
EOF
  fi

  APPS_DNS_STACK_NAME="${CLUSTER_NAME}-apps-dns"
  echo ${APPS_DNS_STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  REGION="${LEASED_RESOURCE}"

  private_route53_hostzone_name="${CLUSTER_NAME}.${BASE_DOMAIN}"
  private_route53_hostzone_id=$(aws route53 list-hosted-zones-by-name --dns-name "${private_route53_hostzone_name}" --max-items 1 | jq -r '.HostedZones[].Id' | awk -F '/' '{print $3}')
  router_lb=$(oc -n openshift-ingress get service router-default -o json | jq -r '.status.loadBalancer.ingress[].hostname')

  if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
    router_lb_hostzone_id=$(aws --region ${REGION} elb describe-load-balancers | jq -r ".LoadBalancerDescriptions[] | select(.DNSName == \"${router_lb}\").CanonicalHostedZoneNameID")
    aws --region "${REGION}" cloudformation create-stack --stack-name ${APPS_DNS_STACK_NAME} \
      --template-body 'file:///tmp/ingress_app.yml' \
      --parameters \
      ParameterKey=PrivateHostedZoneId,ParameterValue=${private_route53_hostzone_id} \
      ParameterKey=PrivateHostedZoneName,ParameterValue=${private_route53_hostzone_name} \
      ParameterKey=RouterLbDns,ParameterValue=${router_lb} \
      ParameterKey=RouterLbHostedZoneId,ParameterValue=${router_lb_hostzone_id} \
      --capabilities CAPABILITY_NAMED_IAM &
    wait "$!"
    ret=$?
  fi

  if [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
    aws --region "${REGION}" cloudformation create-stack --stack-name ${APPS_DNS_STACK_NAME} \
      --template-body 'file:///tmp/ingress_app.yml' \
      --parameters \
      ParameterKey=PrivateHostedZoneId,ParameterValue=${private_route53_hostzone_id} \
      ParameterKey=PrivateHostedZoneName,ParameterValue=${private_route53_hostzone_name} \
      ParameterKey=RouterLbDns,ParameterValue=${router_lb} \
      --capabilities CAPABILITY_NAMED_IAM &
    wait "$!"
    ret=$?
  fi    
    
  echo "Created stack $APPS_DNS_STACK_NAME"

  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${APPS_DNS_STACK_NAME}" &
  wait "$!"
  ret=$?
  echo "Waited for stack $APPS_DNS_STACK_NAME"

  # completing installation
  openshift-install --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"

  echo "Waited for stack $APPS_DNS_STACK_NAME"
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
