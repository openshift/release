#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'save_artifacts; if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

function save_artifacts()
{
    set +o errexit
    cp "${install_dir}/metadata.json" "${SHARED_DIR}/cluster-2-metadata.json"
    cp "${install_dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

    current_time=$(date +%s)
    sed '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${install_dir}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_2_openshift_install-${current_time}.log"

    if [ -d "${install_dir}/.clusterapi_output" ]; then
        mkdir -p "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}"
        cp -rpv "${install_dir}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}" 2>/dev/null
    fi

    set -o errexit
}

function scale_up_worker_nodes()
{
    local machineset_name replicas total_nodes_count ret=0
    total_nodes_count=$(oc get node --no-headers | grep worker | wc -l)
    machineset_name=$(oc -n openshift-machine-api get -o "jsonpath={range .items[*]}{.metadata.name}{'\\n'}{end}" machinesets | grep worker | head -n1)
    replicas=$(oc get machineset ${machineset_name} -n openshift-machine-api -o "jsonpath={.spec.replicas}")

    echo "scale up worker on machineset ${machineset_name}..."
    timeout 5m oc scale --replicas=$((replicas+1)) machineset ${machineset_name} -n openshift-machine-api || ret=1

    if test "${ret}" -eq 0; then
        total_nodes_count=$((total_nodes_count+1))
        try=0
        max_try=30
        while [[ ${try} -lt ${max_try} ]]; do
            if [[ $(oc get node --no-headers | grep worker | grep -c 'Ready') -eq ${total_nodes_count} ]]; then
                echo "INFO: new worker gets ready"
                break
            fi
            echo "wait for new worker gets ready..."
            sleep 60
            try=$(( try + 1 ))
        done

        if [ X"${try}" == X"${max_try}" ]; then
            echo "ERROR: new worker is not ready!"
            run_command "oc get node"
            ret=1
        fi
    else
        echo "ERROR: Scaleup machineset ${machineset_name} FAILED!"
        ret=1
    fi
    return ${ret}
}

# -------------------------------------------------------------------------------------
# health check from step cucushift-installer-check-cluster-health
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

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

check_result=0

cluster_name="${NAMESPACE}-${UNIQUE_HASH}-second"
install_dir="/tmp/${cluster_name}"
mkdir -p ${install_dir}
cat "${SHARED_DIR}/install-config.yaml" > "${install_dir}/install-config.yaml"

#Update clustername
yq-go w -i "${install_dir}/install-config.yaml" 'metadata.name' "${cluster_name}"

echo "Creating 2nd cluster within same subnets as 1st cluster..."
cat "${install_dir}/install-config.yaml" | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/cluster-2-install-config.yaml
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
openshift-install create cluster --dir="${install_dir}" 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
check_result="$?"
echo "Installer exit with code $check_result"

if test "${check_result}" -eq 0 ; then
    echo "Health check..."
    if [[ -f ${install_dir}/auth/kubeconfig ]]; then
        export KUBECONFIG=${install_dir}/auth/kubeconfig
        health_check || exit 1

        if scale_up_worker_nodes; then
            echo "Health check after scaling up on 2nd cluster...."
            health_check || exit 1
        else
            echo "ERROR: scale up on 2nd cluster failed!"
            exit 1
        fi
    else
        echo "Error: no kubeconfig found for 2nd cluster!"
        exit 1
    fi
else
    echo "ERROR: 2nd cluster creation failed!"
    exit 1
fi

#Scale up worker node on 1st cluster
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if scale_up_worker_nodes; then
    echo "Health check after scaling up on 1st cluster...."
    health_check || check_result=1
else
    echo "ERROR: scale up on 1st cluster failed!"
    check_result=1
fi

exit ${check_result}
