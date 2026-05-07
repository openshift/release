#!/bin/bash


set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'metadata.name')"
BASE_DOMAIN="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'baseDomain')"

which openshift-install

function get_arch() {
  ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
  echo "${ARCH}"
}

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

  # Copy CAPI-generated artifacts if they exist
  if [ -d "${dir}/.clusterapi_output" ]; then
    echo "Copying Cluster API generated manifests..."
    mkdir -p "${ARTIFACT_DIR}/clusterapi_output/"
    cp -rpv "${dir}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output/" 2>/dev/null
  fi

  # Capture infrastructure issue log to help gather the datailed failure message in junit files
  if [[ "$ret" == "4" ]] || [[ "$ret" == "5" ]]; then
    grep -Er "Throttling: Rate exceeded|\
rateLimitExceeded|\
The maximum number of [A-Za-z ]* has been reached|\
The number of .* is larger than the maximum allowed size|\
Quota .* exceeded|\
Cannot create more than .* for this subscription|\
The request is being throttled as the limit has been reached|\
SkuNotAvailable|\
Exceeded limit .* for zone|\
Operation could not be completed as it results in exceeding approved .* quota|\
A quota has been reached for project|\
LimitExceeded.*exceed quota" ${ARTIFACT_DIR} > "${SHARED_DIR}/install_infrastructure_failure.log" || true
  fi
}

function prepare_next_steps() {
  local exit_code="${1:-0}"
  # Save exit code for must-gather to generate junit
  echo "${exit_code}" > "${SHARED_DIR}/install-status.txt"
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
  
   # capture install duration for post e2e-analysis
  awk '/Time elapsed per stage:/,/Time elapsed:/' "${dir}/.openshift_install.log" > "${SHARED_DIR}/install-duration.log"

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

function write_ingress_cfn_template() {
    local cfn_template="${1}"

    if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
        cat > "${cfn_template}" << 'CFNEOF'
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
CFNEOF
    elif [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
        cat > "${cfn_template}" << 'CFNEOF'
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
CFNEOF
    else
        echo "Unsupported CLUSTER_TYPE for ingress CloudFormation template: ${CLUSTER_TYPE}"
        return 1
    fi
}

function create_ingress_dns_record() {
    # Background watcher: creates *.apps DNS record during 'create cluster'
    # instead of after it times out. Saves a lot of time when
    # ADD_INGRESS_RECORDS_MANUALLY=yes.
    set +e

    # Wait for kubeconfig to become available (created early in create cluster)
    local kubeconfig="${dir}/auth/kubeconfig"
    local kube_try=0
    while [ ! -f "${kubeconfig}" ] && [ "${kube_try}" -lt 60 ]; do
        sleep 10
        kube_try=$((kube_try + 1))
    done
    if [ ! -f "${kubeconfig}" ]; then
        echo "DNS watcher: ERROR - kubeconfig not found after 10 minutes"
        return 1
    fi
    echo "DNS watcher: kubeconfig available"
    export KUBECONFIG="${kubeconfig}"
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

    # Wait for the router-default service to get a load balancer hostname
    local try=0 retries=40
    local router_lb=""
    while [ "${try}" -lt "${retries}" ]; do
        router_lb=$(oc -n openshift-ingress get service router-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) || true
        if [ -n "${router_lb}" ]; then
            break
        fi
        echo "DNS watcher: waiting for router-default LB (attempt $((try + 1))/${retries})..."
        sleep 30
        try=$((try + 1))
    done
    if [ -z "${router_lb}" ]; then
        echo "DNS watcher: ERROR - router-default LB not found after ${retries} attempts"
        return 1
    fi
    echo "DNS watcher: router LB found: ${router_lb}"

    # Look up the private hosted zone
    local private_route53_hostzone_name="${CLUSTER_NAME}.${BASE_DOMAIN}"
    local private_route53_hostzone_id
    private_route53_hostzone_id=$(aws route53 list-hosted-zones-by-name --dns-name "${private_route53_hostzone_name}" --max-items 1 | jq -r '.HostedZones[].Id' | awk -F '/' '{print $3}')
    if [ -z "${private_route53_hostzone_id}" ]; then
        echo "DNS watcher: ERROR - private hosted zone not found for ${private_route53_hostzone_name}"
        return 1
    fi
    echo "DNS watcher: private hosted zone: ${private_route53_hostzone_id}"

    # Write CloudFormation template
    local cfn_template="/tmp/ingress_app_bg.yml"
    write_ingress_cfn_template "${cfn_template}" || return 1

    # Create CloudFormation stack
    local APPS_DNS_STACK_NAME="${CLUSTER_NAME}-apps-dns"
    echo "${APPS_DNS_STACK_NAME}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
    local REGION="${LEASED_RESOURCE}"

    if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
        local router_lb_hostzone_id
        if is_dualstack; then
            router_lb_hostzone_id=$(aws --region "${REGION}" elbv2 describe-load-balancers | jq -r ".LoadBalancers[] | select(.DNSName == \"${router_lb}\").CanonicalHostedZoneId")
        else
            router_lb_hostzone_id=$(aws --region "${REGION}" elb describe-load-balancers | jq -r ".LoadBalancerDescriptions[] | select(.DNSName == \"${router_lb}\").CanonicalHostedZoneNameID")
        fi

        aws --region "${REGION}" cloudformation create-stack --stack-name "${APPS_DNS_STACK_NAME}" \
            --template-body "file://${cfn_template}" \
            --parameters \
            ParameterKey=PrivateHostedZoneId,ParameterValue="${private_route53_hostzone_id}" \
            ParameterKey=PrivateHostedZoneName,ParameterValue="${private_route53_hostzone_name}" \
            ParameterKey=RouterLbDns,ParameterValue="${router_lb}" \
            ParameterKey=RouterLbHostedZoneId,ParameterValue="${router_lb_hostzone_id}" \
            --capabilities CAPABILITY_NAMED_IAM || return 1
    elif [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
        aws --region "${REGION}" cloudformation create-stack --stack-name "${APPS_DNS_STACK_NAME}" \
            --template-body "file://${cfn_template}" \
            --parameters \
            ParameterKey=PrivateHostedZoneId,ParameterValue="${private_route53_hostzone_id}" \
            ParameterKey=PrivateHostedZoneName,ParameterValue="${private_route53_hostzone_name}" \
            ParameterKey=RouterLbDns,ParameterValue="${router_lb}" \
            --capabilities CAPABILITY_NAMED_IAM || return 1
    fi

    aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${APPS_DNS_STACK_NAME}" || return 1

    echo "DNS watcher: *.apps DNS record created successfully via stack ${APPS_DNS_STACK_NAME}"
    return 0
}

function patch_public_ip_for_edge_node() {
  set -x
  local dir=${1}
  
  pushd "${dir}/openshift"

  # For wavelength zone & byo vpc only
  if [[ "${EDGE_ZONE_TYPES:-}"  == 'wavelength-zone' ]] && [[ -e ${SHARED_DIR}/edge_zone_subnet_id ]]; then

    if [ ! -f /tmp/yq ]; then
      curl -L "https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_$( get_arch )" \
      -o /tmp/yq && chmod +x /tmp/yq
    fi
    
    PATCH=$(mktemp)
    cat <<EOF > ${PATCH}
spec:
  template:
    spec:
      providerSpec:
        value:
          publicIp: true
EOF

    SUBNET_ID=$(head -n 1 ${SHARED_DIR}/edge_zone_subnet_id)

    echo "wavelength zone: patching publi ip: ${PATCH}"

    for MACHINESET in $(grep -lr "machine.openshift.io/cluster-api-machine-role: edge" .)
    do
      echo -e "\tpatching: ${MACHINESET}"
      sed -i "s/subnet-.*/${SUBNET_ID}/g" ${MACHINESET}
      /tmp/yq m -x -i "${MACHINESET}" "${PATCH}"
    done
  fi
  popd
  set +x
}

# enable_efa_pg_instance_config is an AWS specific option that enables one worker machineset in a placement group and with EFA Network Interface Type, other worker machinesets will be ENA Network Interface Type by default.....
function enable_efa_pg_instance_config() {
  local dir=${1}

  PATCH="${SHARED_DIR}/machineset0-efa-pg.yaml.patch"
  cat > "${PATCH}" << EOF
spec:
  template:
    spec:
      providerSpec:
        value:
          networkInterfaceType: EFA
          instanceType: c5n.9xlarge
          placementGroupName: pgcluster
EOF
  yq-go m -x -i "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" "${PATCH}"
  echo 'Patched efa pg into 99_openshift-cluster-api_worker-machineset-0.yaml'
}

function is_dualstack() {
  if [[ "${IP_FAMILY:-}" == *"DualStack"* ]]; then
    return 0
  else
    return 1
  fi
}

# shellcheck disable=SC2329  # invoked from EXIT/TERM trap
function cleanup() {
  local exit_code=$?

  # Kill any background jobs
  local pid
  while read -r pid; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null || true
  done < <(jobs -p)
  wait 2>/dev/null || true

  prepare_next_steps "${exit_code}"

  # Remove the EXIT trap so we aren't called again
  trap - EXIT
  exit "${exit_code}"
}
trap cleanup EXIT TERM

export INSTALLER_BINARY="openshift-install"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "User specified a custom payload for cluster install, overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}

  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
elif [[ "${USE_ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" == "true" ]]; then
  ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$(KUBECONFIG="" oc get is release -o jsonpath='{range .status.tags[*].items[*]}{.image}{" "}{.dockerImageReference}{"\n"}{end}' | grep "^$(echo "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" | sed 's/.*@//')" | awk '{print $2}')
  echo "User want the original payload for cluster install, overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${ORIGINAL_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
${INSTALLER_BINARY} version
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
aws|aws-arm64|aws-usgov|aws-eusc)
    if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
        echo "Setting AWS credential with minimal permision for installer"
        export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
    else
        export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    fi
    ;;
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

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

# ---------------------------------------------------------
# manifests
# ---------------------------------------------------------
${INSTALLER_BINARY} --dir="${dir}" create manifests &
wait "$!"

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then
  yq-go d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.privateZone
  yq-go d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.publicZone
fi

if [ "${ENABLE_AWS_EDGE_ZONE}" == "yes" ]; then
  if [[ -f "${SHARED_DIR}/manifest_edge_node_machineset.yaml" ]]; then
    # Phase 0, inject manifests
    
    # replace PLACEHOLDER_INFRA_ID PLACEHOLDER_AMI_ID
    echo "Local Zone is enabled, updating Infran ID and AMI ID ... "
    edge_node_machineset="${SHARED_DIR}/manifest_edge_node_machineset.yaml"
    infra_id=$(jq -r '."*installconfig.ClusterID".InfraID' "${dir}/.openshift_install_state.json")
    ami_id=$(grep ami "${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml" | tail -n1 | awk '{print$2}')
    sed -i "s/PLACEHOLDER_INFRA_ID/$infra_id/g" ${edge_node_machineset}
    sed -i "s/PLACEHOLDER_AMI_ID/$ami_id/g" ${edge_node_machineset}
    cp "${edge_node_machineset}" "${ARTIFACT_DIR}/"
  else
    # Phase 1 & 2, use install-config
    if [[ "${EDGE_NODE_WORKER_SCHEDULABLE}" == "yes" ]]; then
      echo 'EDGE_NODE_WORKER_SCHEDULABLE is set to "yes", removing spec.template.spec.taints from edge node machineset'
      for edge_node_machineset in $(grep -lr 'cluster-api-machine-type: edge' ${dir});
      do
        echo "Removing spec.template.spec.taints from $(basename ${edge_node_machineset})"
        yq-go d "${edge_node_machineset}" spec.template.spec.taints
      done
    fi
  fi

  if [[ "${EDGE_NODE_WORKER_ASSIGN_PUBLIC_IP:-}"  == 'yes' ]]; then
    patch_public_ip_for_edge_node ${dir}
  fi
  
fi

if [[ "${ENABLE_AWS_EFA_PG_INSTANCE:-}"  == 'true' ]]; then
  enable_efa_pg_instance_config ${dir}
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

${INSTALLER_BINARY} --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
INSTALL_PID=$!

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then
    echo "Starting background DNS watcher for manual ingress record creation..."
    create_ingress_dns_record &
    DNS_WATCHER_PID=$!
fi

set +e
wait "${INSTALL_PID}"
ret="$?"
set -e

if test "${ret}" -ne 0 ; then
  echo "Installation failed [create cluster]"
fi

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then

  # Wait for background DNS watcher to finish
  echo "Checking background DNS watcher status..."
  set +e
  wait "${DNS_WATCHER_PID}"
  dns_ret=$?
  set -e

  if [ "${dns_ret}" -eq 0 ]; then
    echo "Background DNS watcher completed successfully"
  else
    echo "ERROR: Background DNS watcher failed (exit code: ${dns_ret})"
    exit 1
  fi

  # completing installation
  export KUBECONFIG="${dir}/auth/kubeconfig"
  ${INSTALLER_BINARY} --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
