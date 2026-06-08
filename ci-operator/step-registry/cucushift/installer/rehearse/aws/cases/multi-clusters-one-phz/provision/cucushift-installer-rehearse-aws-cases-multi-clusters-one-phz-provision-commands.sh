#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi      
        
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# -----------------------------------------
# OCP-41246 - [ipi-on-aws] Create multiple clusters into one existing Route53 hosted zone
# -----------------------------------------

trap 'save_artifacts' EXIT TERM INT

function save_artifacts()
{
  set +o errexit
  current_time=$(date +%s)
  cp "${install_dir1}/metadata.json" "${SHARED_DIR}/cluster-1-metadata.json"
  cp "${install_dir2}/metadata.json" "${SHARED_DIR}/cluster-2-metadata.json"

  cp "${install_dir1}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  cp "${install_dir2}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir1}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_1_openshift_install-${current_time}.log"
  
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir2}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_2_openshift_install-${current_time}.log"

  
  if [ -d "${install_dir1}/.clusterapi_output" ]; then
    mkdir -p "${ARTIFACT_DIR}/cluster_1_clusterapi_output-${current_time}"
    cp -rpv "${install_dir1}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/cluster_1_clusterapi_output-${current_time}" 2>/dev/null
  fi

  if [ -d "${install_dir2}/.clusterapi_output" ]; then
    mkdir -p "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}"
    cp -rpv "${install_dir2}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}" 2>/dev/null
  fi

  set -o errexit
}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}
CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
ROUTE53_HOSTED_ZONE_NAME="${CLUSTER_PREFIX}.${BASE_DOMAIN}"
subnet_ids_file="${SHARED_DIR}/subnet_ids"

HOSTED_ZONE_ID_FILE="${SHARED_DIR}/hosted_zone_id"
if [ ! -f "${HOSTED_ZONE_ID_FILE}" ]; then
  echo "File ${HOSTED_ZONE_ID_FILE} does not exist."
  exit 1
fi
HOSTED_ZONE_ID="$(cat ${HOSTED_ZONE_ID_FILE})"

# -----------------------------------------
# Create install-config
# -----------------------------------------
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

function create_install_config()
{
  local cluster_name=$1
  local install_dir=$2

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${ROUTE53_HOSTED_ZONE_NAME}
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
    hostedZone: ${HOSTED_ZONE_ID}
    subnets: $(cat "${subnet_ids_file}")
publish: Internal
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

  patch=$(mktemp)
  if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
    cat > "${patch}" << EOF
controlPlane:
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
EOF
    yq-go m -x -i ${install_dir}/install-config.yaml "${patch}"
  fi

  if [[ ${COMPUTE_NODE_TYPE} != "" ]]; then
    cat > "${patch}" << EOF
compute:
- platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF
    yq-go m -x -i ${install_dir}/install-config.yaml "${patch}"
  fi
}

# -----------------------------------------
# Create clusters
# -----------------------------------------

cluster_name1="${CLUSTER_PREFIX}1"
cluster_name2="${CLUSTER_PREFIX}2"
install_dir1=/tmp/${cluster_name1}
install_dir2=/tmp/${cluster_name2}

mkdir -p ${install_dir1} 2>/dev/null
mkdir -p ${install_dir2} 2>/dev/null

create_install_config $cluster_name1 $install_dir1
create_install_config $cluster_name2 $install_dir2

# enable proxy
source "${SHARED_DIR}/proxy-conf.sh"

echo "Creating cluster 1"
cat ${install_dir1}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/cluster-1-install-config.yaml
openshift-install --dir="${install_dir1}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"
echo "Installer exit with code $ret"

echo "Creating cluster 2"
cat ${install_dir2}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/cluster-2-install-config.yaml
openshift-install --dir="${install_dir2}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"
echo "Installer exit with code $ret"

# disable proxy
source "${SHARED_DIR}/unset-proxy.sh"

infra_id1=$(jq -r '.infraID' ${install_dir1}/metadata.json)
infra_id2=$(jq -r '.infraID' ${install_dir2}/metadata.json)

# "shared" tags were added
ret=0
aws --region $REGION route53 list-tags-for-resource --resource-type hostedzone --resource-id "${HOSTED_ZONE_ID}" | jq -r '.ResourceTagSet.Tags | from_entries' > ${ARTIFACT_DIR}/phz_tags.json

if ! grep -qE "kubernetes.io/cluster/${infra_id1}.*shared" ${ARTIFACT_DIR}/phz_tags.json; then
  echo "ERROR: ${HOSTED_ZONE_ID}: NOT found tag kubernetes.io/cluster/${infra_id1}:shared"
  ret=$((ret+1))
else
  echo "PASS: ${HOSTED_ZONE_ID}: Found tag kubernetes.io/cluster/${infra_id1}:shared"
fi

if ! grep -qE "kubernetes.io/cluster/${infra_id2}.*shared" ${ARTIFACT_DIR}/phz_tags.json; then
  echo "ERROR: ${HOSTED_ZONE_ID}: NOT found tag kubernetes.io/cluster/${infra_id2}:shared"
  ret=$((ret+1))
else
  echo "PASS: ${HOSTED_ZONE_ID}: Found tag kubernetes.io/cluster/${infra_id2}:shared"
fi


# -------------------------------------------------------------------------------------
# health check
# -------------------------------------------------------------------------------------


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


set +e

# enable proxy
source "${SHARED_DIR}/proxy-conf.sh"

echo "Health check for cluster 1:"
if [[ -f ${install_dir1}/auth/kubeconfig ]]; then
  export KUBECONFIG=${install_dir1}/auth/kubeconfig
  health_check
  health_ret=$?
  ret=$((ret+health_ret))
else
  echo "Error: no kubeconfig found for cluster 1"
  ret=$((ret+1))
fi


echo "Health check for cluster 2:"
if [[ -f ${install_dir2}/auth/kubeconfig ]]; then
  export KUBECONFIG=${install_dir2}/auth/kubeconfig
  health_check
  health_ret=$?
  ret=$((ret+health_ret))
else
  echo "Error: no kubeconfig found for cluster 2"
  ret=$((ret+1))
fi

exit $ret
