#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
else
  export INSTALLER_BINARY="openshift-install"
fi

# -----------------------------------------
# 
# -----------------------------------------

trap 'post_actions' EXIT TERM INT
INSTALL_BASE_DIR=/tmp/install_base_dir

CLUSTER_NAME_1="${NAMESPACE}-${UNIQUE_HASH}-1"
INSTALL_DIR_1=${INSTALL_BASE_DIR}/${CLUSTER_NAME_1}
CLUSTER_NAME_2="${NAMESPACE}-${UNIQUE_HASH}-2"
INSTALL_DIR_2=${INSTALL_BASE_DIR}/${CLUSTER_NAME_2}

mkdir -p ${INSTALL_DIR_1} ${INSTALL_DIR_2}

function post_actions()
{
  set +o errexit
  pushd $INSTALL_BASE_DIR
  find . -name "log-bundle-*.tar.gz" -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find . -name .openshift_install.log -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find ${ARTIFACT_DIR} -name .openshift_install.log -exec sed -i 's/password: .*/password: REDACTED/; s/X-Auth-Token.*/X-Auth-Token REDACTED/; s/UserData:.*,/UserData: REDACTED,/;' '{}' \;

  cp ${INSTALL_DIR_1}/metadata.json ${SHARED_DIR}/cluster-1-metadata.json
  cp ${INSTALL_DIR_2}/metadata.json ${SHARED_DIR}/cluster-2-metadata.json

  popd
  set -o errexit
}


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
ret=0

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version unavailable_operator degraded_operator skip_operator

    local skip_operator="aro" # ARO operator versioned but based on RP git commit ID not cluster version

    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    oc get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"

    echo "Make sure every operator column reports version"
    if null_version=$(oc get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
      echo >&2 "Null Version: ${null_version}"
      (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(oc get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${EXPECTED_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(oc get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are not Available, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(oc get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's DEGRADED column is False"
    if degraded_operator=$(oc get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        if check_clusteroperators; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        else
            echo "cluster operators are not ready yet, wait and retry..."
            continous_successful_check=0
        fi
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        echo "Debug: current CO output is:"
        oc get co
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function check_mcp() {
    local updating_mcp unhealthy_mcp tmp_output

    tmp_output=$(mktemp)
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        updating_mcp=$(cat "${tmp_output}" | grep -v "False")
        if [[ -n "${updating_mcp}" ]]; then
            echo "Some mcp is updating..."
            echo "${updating_mcp}"
            return 1
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
        if [[ -n "${unhealthy_mcp}" ]]; then
            echo "Detected unhealthy mcp:"
            echo "${unhealthy_mcp}"
            echo "Real-time detected unhealthy mcp:"
            oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            echo "Real-time full mcp output:"
            oc get machineconfigpools
            echo ""
            unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
            echo "Using oc describe to check status of unhealthy mcp ..."
            for mcp_name in ${unhealthy_mcp_names}; do
              echo "Name: $mcp_name"
              oc describe mcp $mcp_name || echo "oc describe mcp $mcp_name failed"
            done
            return 2
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=5 max_retries=20 ret=0
    local continous_degraded_check=0 degraded_criteria=5
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        ret=0
        check_mcp || ret=$?
        if [[ "$ret" == "0" ]]; then
            continous_degraded_check=0
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        elif [[ "$ret" == "1" ]]; then
            echo "Some machines are updating..."
            continous_successful_check=0
            continous_degraded_check=0
        else
            continous_successful_check=0
            echo "Some machines are degraded #${continous_degraded_check}..."
            (( continous_degraded_check += 1 ))
            if (( continous_degraded_check >= degraded_criteria )); then
                break
            fi
        fi
        echo "wait and retry..."
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get machineconfigpools
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | wc -l)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    local soptted_pods

    soptted_pods=$(oc get pod --all-namespaces | grep -Evi "running|Completed" |grep -v NAMESPACE)
    if [[ -n "$soptted_pods" ]]; then
        echo "There are some abnormal pods:"
        echo "${soptted_pods}"
    fi
    echo "Show all pods for reference/debug"
    run_command "oc get pods --all-namespaces"
}

function health_check() {

  EXPECTED_VERSION=$(oc get clusterversion/version -o json | jq -r '.status.history[0].version')
  export EXPECTED_VERSION

  run_command "oc get machineconfig"

  echo "Step #1: Make sure no degrated or updating mcp"
  wait_mcp_continous_success || return 1

  echo "Step #2: check all cluster operators get stable and ready"
  wait_clusteroperators_continous_success || return 1

  echo "Step #3: Make sure every machine is in 'Ready' status"
  check_node || return 1

  echo "Step #4: check all pods are in status running or complete"
  check_pod || return 1
}


function create_install_config()
{
  local cluster_name=$1
  local install_dir=$2

  local config
  config=${install_dir}/install-config.yaml

  cat > ${config} << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: ${OCP_ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: ${OCP_ARCH}
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${cluster_name}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
publish: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

  if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
    yq-v4 eval -i '.controlPlane.platform.aws.type = env(CONTROL_PLANE_INSTANCE_TYPE)' "${config}"
  fi

  if [[ ${COMPUTE_NODE_TYPE} != "" ]]; then
    yq-v4 eval -i '.compute[0].platform.aws.type = env(COMPUTE_NODE_TYPE)' "${config}"
  fi
}

function save_resources_info()
{
    local infra_id=$1
    local vpc_id=$2
    local prefix=$3
    
    for tag in "kubernetes.io/cluster/${infra_id}" "sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id}";
    do
        for value in "owned" "shared";
        do
            aws --region $REGION resourcegroupstaggingapi get-resources --tag-filters Key=${tag},Values=${value} > ${ARTIFACT_DIR}/${prefix}_resources_tags_${infra_id}_${value}_${tag:0:4}.json
        done
    done
    aws --region $REGION elb describe-load-balancers | jq -r --arg v $vpc_id '[.LoadBalancerDescriptions[] | select(.VPCId==$v)]' > ${ARTIFACT_DIR}/${prefix}_elbv1.json
    aws --region $REGION elbv2 describe-load-balancers | jq -r --arg v $vpc_id '[.LoadBalancers[] | select(.VpcId==$v)]' > ${ARTIFACT_DIR}/${prefix}_elbv2.json
}

function create_cluster()
{
    local cluster_name=$1
    local install_dir=$2

    echo "install-config.yaml:"
    yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' ${install_dir}/install-config.yaml > /tmp/ic-summary.yaml
    yq-v4 e /tmp/ic-summary.yaml

    # Create 1st cluster
    ${INSTALLER_BINARY} create manifests --dir ${install_dir} &
    wait "$!"

    ${INSTALLER_BINARY} create cluster --dir ${install_dir} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
    wait "$!"

    export KUBECONFIG=${install_dir}/auth/kubeconfig
    health_check
}

# ------------------------------------------------------------
# Create Cluster 1
# ------------------------------------------------------------
echo "********** Creating Cluster 1"
create_install_config ${CLUSTER_NAME_1} ${INSTALL_DIR_1}
create_cluster ${CLUSTER_NAME_1} ${INSTALL_DIR_1}
infra_id_1=$(jq -r '.infraID' ${INSTALL_DIR_1}/metadata.json)
aws --region ${REGION} ec2 describe-subnets --filters Name=tag:"kubernetes.io/cluster/${infra_id_1}",Values=owned > /tmp/subnets.json
vpc_id=$(jq -r '.Subnets[0].VpcId' /tmp/subnets.json)
save_resources_info ${infra_id_1} ${vpc_id} "phase_1_created_the_first_cluster"

# ------------------------------------------------------------
# Create Cluster 2
# ------------------------------------------------------------
echo "********** Creating Cluster 2"
create_install_config ${CLUSTER_NAME_2} ${INSTALL_DIR_2}

# subnets
jq -r '[.Subnets[].SubnetId]' /tmp/subnets.json | yq-v4 > /tmp/subnets.yaml
yq-v4 eval -i '.platform.aws.subnets = load("/tmp/subnets.yaml")' ${INSTALL_DIR_2}/install-config.yaml

create_cluster ${CLUSTER_NAME_2} ${INSTALL_DIR_2}
infra_id_2=$(jq -r '.infraID' ${INSTALL_DIR_2}/metadata.json)

for infra_id in ${infra_id_1} ${infra_id_2};
do
    save_resources_info ${infra_id} ${vpc_id} "phase_2_created_two_clusters"
done


# ------------------------------------------------------------
# Destroy Cluster 1
# ------------------------------------------------------------
echo "********** Destroy Cluster 1"
${INSTALLER_BINARY} destroy cluster --dir ${INSTALL_DIR_1}

# ------------------------------------------------------------
# Check Cluster 2
# ------------------------------------------------------------
echo "********** Check Cluster 2"
export KUBECONFIG=${INSTALL_DIR_2}/auth/kubeconfig
health_check
