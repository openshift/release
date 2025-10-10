#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'post_step_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json

# Instance types list to be tested
INSTANCE_TYPE_LIST=${ARTIFACT_DIR}/instance_types.yaml
cat > ${INSTANCE_TYPE_LIST} <<EOF
- master: Standard_D4as_v5
  worker: Standard_E2s_v3
  region: eastus2
- master: Standard_B4ms
  worker: Standard_E64is_v3
  region: eastus2
- master: Standard_D4ads_v5
  worker: Standard_E96ias_v4
  region: eastus2
- master: Standard_D4as_v4
  worker: Standard_E104ids_v5
  region: eastus2
- master: Standard_DC4s_v3
  worker: Standard_E104is_v5
  region: eastus2
- master: Standard_DC4ds_v3
  worker: Standard_D2s_v4
  region: eastus2
- master: Standard_D4ds_v4
  worker: Standard_M192ids_v2
  region: centralus
- master: Standard_D8lds_v5
  worker: Standard_D4ls_v5
  region: westus
- master: Standard_DS4
  worker: Standard_M32dms_v2
  region: southcentralus
- master: Standard_E4s_v4
  worker: Standard_DS3_v2
  region: eastus2
- master: Standard_DS12_v2_Promo
  worker: Standard_D2s_v5
  region: westus3
- master: Standard_NC24rs_v3
  worker: Standard_E80is_v4
  region: centralus
- master: Standard_E4as_v5
  worker: Standard_E2ds_v4
  region: eastus2
- master: Standard_E4bds_v5
  worker: Standard_NV12s_v3
  region: westus
- master: Standard_E4s_v5
  worker: Standard_F4s
  region: westus2
- master: Standard_F8s_v2
  worker: Standard_D4ds_v5
  region: eastus2
- master: Standard_FX4mds
  worker: Standard_D2s_v3
  region: westeurope
- master: Standard_GS2
  worker: Standard_L4s
  region: australiaeast
- master: Standard_HC44-16rs
  worker: Standard_L8as_v3
  region: eastus2
- master: Standard_L8s_v2
  worker: Standard_M192is_v2
  region: centralus
- master: Standard_L8s_v3
  worker: Standard_D4s_v3
  region: westus2
- master: Standard_D4s_v5
  worker: Standard_NC24ads_A100_v4
  region: eastus
- master: Standard_NP10s
  worker: Standard_ND40rs_v2
  region: southcentralus
- master: Standard_NC4as_T4_v3
  worker: Standard_NV12ads_A10_v5
  region: southcentralus
  worker_scaleup: Standard_HB120-16rs_v2
- master: Standard_E4bs_v5
  worker: Standard_M32ms_v2
  region: centralus
- master: Standard_E4ds_v5
  worker: Standard_E112ias_v5
  region: eastus2
- master: Standard_M8-4ms
  worker: Standard_DC4s_v2
  region: southcentralus
- master: Standard_B8ls_v2
  worker: Standard_HX176-24rs
  region: eastus
- master: Standard_B4as_v2
  worker: Standard_NG8ads_V620_v1
  region: westeurope
- master: Standard_DC4as_cc_v5
  worker: Standard_DC4ads_cc_v5
  region: eastus
- master: Standard_EC4as_cc_v5
  worker: Standard_EC4ads_cc_v5
  region: westeurope
- master: Standard_M12ds_v3
  worker: Standard_M12s_v3
  region: eastus
- master: Standard_E4ads_v5
  worker: Standard_NV4ads_V710_v5
  region: westus
- master: Standard_E4as_v4
  worker: Standard_E112iads_v5
  region: southcentralus
- master: Standard_D8ds_v6
  worker: Standard_D4s_v6
  region: westus
- master: Standard_D8ls_v6
  worker: Standard_D4lds_v6
  region: westus
- master: Standard_L8s_v4
  worker: Standard_L8as_v4
  region: eastus 
EOF

INSTALL_BASE_DIR=/tmp/install_base_dir
mkdir -p ${INSTALL_BASE_DIR}
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
ret=0

IC_CONTROL_PLANE_NODE_COUNT=3
IC_COMPUTE_NODE_COUNT=2
REGION_SPILT_NUMBER=3

# following regions will be tested
MASTER_INSTANCE_TYPE_LIST=${ARTIFACT_DIR}/instance_types_master.txt
RESULT=${ARTIFACT_DIR}/result.json
echo '{}' > ${RESULT}


function post_step_actions()
{
  set +o errexit
  pushd $INSTALL_BASE_DIR
  find . -name "log-bundle-*.tar.gz" -exec cp --parents '{}' ${ARTIFACT_DIR}  \;

  find . -name .openshift_install.log -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find ${ARTIFACT_DIR} -name .openshift_install.log -exec sed -i 's/password: .*/password: REDACTED/; s/X-Auth-Token.*/X-Auth-Token REDACTED/; s/UserData:.*,/UserData: REDACTED,/;' '{}' \;
  popd
  set -o errexit

  echo "--- ARTIFACT_DIR ---"
  find ${ARTIFACT_DIR} -type f
  echo "--- INSTALL_BASE_DIR ---"
  find ${INSTALL_BASE_DIR} -type f
  echo "--- RESULTS ---"
  echo -e "master_intance_type\tworker_instance_type\tregion\tcluster_name\tinfra_id\tinstall\thealth_check\tdestroy_result"
  jq -r '.[] | [.master_instance_type, .worker_instance_type, .region, .cluster_name, .infra_id, .install_result, .health_check_result, .destroy_result] | @tsv' $RESULT
}

function generate_instance_types()
{

  yq-go r ${INSTANCE_TYPE_LIST} '.master' | sort > ${MASTER_INSTANCE_TYPE_LIST}
  
  # Split instance type
  if [[ ${SPILT_INSTANCE_TYPE} != "" ]]; then
    echo "Spliting instance types into ${REGION_SPILT_NUMBER} parts ..."
    pushd /tmp/
    total_count=$(cat ${MASTER_INSTANCE_TYPE_LIST} | wc -l)
    each_part_count=$((${total_count}/${REGION_SPILT_NUMBER}+1))
    echo "SPILT_INSTANCE_TYPES: ${SPILT_INSTANCE_TYPE}, total: ${total_count}, each: ${each_part_count}"

    split -l${each_part_count} $MASTER_INSTANCE_TYPE_LIST
    ls xa*

    case "${SPILT_INSTANCE_TYPE}" in
      INSTANCE_TYPE_SET_A)
        cp xaa ${MASTER_INSTANCE_TYPE_LIST}
        ;;
      INSTANCE_TYPE_SET_B)
        cp xab ${MASTER_INSTANCE_TYPE_LIST}
        ;;
      INSTANCE_TYPE_SET_C)
        cp xac ${MASTER_INSTANCE_TYPE_LIST}
        ;;
      *)
        echo "ERROR: Unsuported SPILT_INSTANCE_TYPE: ${SPILT_INSTANCE_TYPE}"
        exit 1
        ;;
    esac
    popd
  fi
}

function get_cluster_name()
{
  local master_instance_type=$1
  echo "${NAMESPACE}-${UNIQUE_HASH}-$(echo ${master_instance_type} | md5sum | cut -c1-3)"
}

function get_install_dir()
{
  local master_instance_type=$1
  echo "${INSTALL_BASE_DIR}/$(get_cluster_name $master_instance_type)"
}

function get_nodes_json()
{
  local master_instance_type=$1
  local t
  t="${ARTIFACT_DIR}/$(get_cluster_name $master_instance_type)/nodes.json"
  if [[ ! -d "$(dirname $t)" ]]; then
    mkdir -p "$(dirname $t)"
  fi
  echo $t
}

function get_machines_json()
{
  local master_instance_type=$1
  local t
  t="${ARTIFACT_DIR}/$(get_cluster_name $master_instance_type)/machines.json"
  if [[ ! -d "$(dirname $t)" ]]; then
    mkdir -p "$(dirname $t)"
  fi
  echo $t
}

function create_install_config()
{
  local master_instance_type=$1
  local worker_instance_type=$2
  local region=$3
  local cluster_name=$4
  local install_dir=$5

  local config
  config=${install_dir}/install-config.yaml

  cat > ${config} << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    azure:
      type: ${worker_instance_type}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: 
    azure:
      type: ${master_instance_type}
  replicas: ${IC_CONTROL_PLANE_NODE_COUNT}
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
  azure:
    baseDomainResourceGroupName: ${BASE_DOMAIN_RESOURCE_GROUP}
    region: ${region}
publish: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

  echo "install-config.yaml:"
  yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' ${install_dir}/install-config.yaml > /tmp/ic-summary.yaml
  yq-v4 e /tmp/ic-summary.yaml
}

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

function all_nodes()
{
  local master_instance_type=$1
  local control_plane_node_count
  local compute_node_count
  local nodes_json
  local node_ret
  local machines_json
  node_ret=0

  nodes_json="$(get_nodes_json $master_instance_type)"
  machines_json="$(get_machines_json $master_instance_type)"

  oc get machines.machine.openshift.io -n openshift-machine-api -ojson > $machines_json
  oc get node -ojson > $nodes_json

  oc get machines.machine.openshift.io -n openshift-machine-api -owide
  oc get node -owide

  control_plane_node_count=$(jq -r '.items | map(select(.metadata.labels."node-role.kubernetes.io/master"?)) | length' "${nodes_json}")
  compute_node_count=$(jq -r '.items | map(select(.metadata.labels."node-role.kubernetes.io/worker"? and (.metadata.labels."node-role.kubernetes.io/edge"? | not))) | length' "${nodes_json}")

  echo "control_plane_node_count: ${control_plane_node_count}, except: ${IC_CONTROL_PLANE_NODE_COUNT}"
  echo "compute_node_count: ${compute_node_count}, except: ${IC_COMPUTE_NODE_COUNT}"

  if [[ "${control_plane_node_count}" != "${IC_CONTROL_PLANE_NODE_COUNT}" ]]; then
      node_ret=$((node_ret+1))
  fi

  if [[ "${compute_node_count}" != "${IC_COMPUTE_NODE_COUNT}" ]]; then
      node_ret=$((node_ret+1))
  fi

  return ${node_ret}
}

function check_node_count()
{
  local master_instance_type=$1
  local try=1
  local total=30
  local interval=60
  while [[ ${try} -le ${total} ]]; do
      echo "Check nodes status (try ${try} / ${total})"

      if ! all_nodes ${master_instance_type}; then
          sleep ${interval}
          (( try++ ))
          continue
      else
          echo "Nodes count is expected."
          return 0
      fi
  done
  return 1
}

function health_check() {

  local master_instance_type=$1

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

  echo "Step #5: check node count"
  check_node_count ${master_instance_type} || return 1
}

function destroy_cluster() {

    local install_dir=$1
    openshift-install destroy cluster --dir ${install_dir} --log-level debug &
    wait "$!"
    destroy_ret="$?"
    ret=$((ret+destroy_ret))

    if [ $destroy_ret -ne 0 ]; then
      report_destroy_result "${master_instance_type}" "FAIL"
    else
      report_destroy_result "${master_instance_type}" "PASS"
    fi
}

function report_install_result()
{
  local master_instance_type=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: INSTALL: ${master_instance_type} $(get_cluster_name $master_instance_type)"
  cat <<< "$(jq --arg master_instance_type ${master_instance_type} --arg m ${fail_or_pass} '.[$master_instance_type].install_result = $m' "${RESULT}")" > ${RESULT}
}

function report_health_check_result()
{
  local master_instance_type=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: HEALTH CHECK: ${master_instance_type} $(get_cluster_name $master_instance_type)"
  cat <<< "$(jq --arg master_instance_type ${master_instance_type} --arg m ${fail_or_pass} '.[$master_instance_type].health_check_result = $m' "${RESULT}")" > ${RESULT}
}

function report_destroy_result()
{
  local master_instance_type=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: DESTROY: ${master_instance_type} $(get_cluster_name $master_instance_type)"
  cat <<< "$(jq --arg region ${master_instance_type} --arg m ${fail_or_pass} '.[$master_instance_type].destroy_result = $m' "${RESULT}")" > ${RESULT}
}

# -------------------------------------------------------------------------------------
# generate regions
# -------------------------------------------------------------------------------------
echo "Getting regions for test ..."
generate_instance_types
echo "Following instance types will be tested:"

# -------------------------------------------------------------------------------------
# init result file
# -------------------------------------------------------------------------------------
echo "Creating result file ..."
t=$(mktemp)
while IFS= read -r master_instance_type; do
    echo "master: ${master_instance_type}, worker:$(yq-go r ${INSTANCE_TYPE_LIST} "(master==$master_instance_type).worker")"
    cat > ${t} << EOF
{
  "master_instance_type": "${master_instance_type}",
  "worker_instance_type": "$(yq-go r ${INSTANCE_TYPE_LIST} "(master==$master_instance_type).worker")",
  "region": "$(yq-go r ${INSTANCE_TYPE_LIST} "(master==$master_instance_type).region")",
  "cluster_name": "$(get_cluster_name "${master_instance_type}")",
  "install_dir": "$(get_install_dir "${master_instance_type}")",
  "infra_id": "NA",
  "install_result": "NA",
  "health_check_result": "NA",
  "destroy_result": "NA"
}
EOF
    cat <<< "$(jq  --argjson info "$(<${t})" --arg master_instance_type $master_instance_type '. += {($master_instance_type): $info}' "${RESULT}")" > ${RESULT}
done < ${MASTER_INSTANCE_TYPE_LIST}

#-------------------------------------------------------------------------------------
# Generate manifests to configure PV for prometheus to test storage
# -------------------------------------------------------------------------------------
echo "Generate manifests to configure PV for prometheus to test storage"
PROMETHEUS_CONFIG="/tmp/manifest-cluster-monitoring-config.yaml"
PATCH="/tmp/cluster-monitoring-config.yaml.patch"

touch $PROMETHEUS_CONFIG

CONFIG_CONTENTS="$(yq-go r ${PROMETHEUS_CONFIG} 'data."config.yaml"')"
if [ -z "${CONFIG_CONTENTS}" ]; then
  cat >> "${PROMETHEUS_CONFIG}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml:
EOF
fi

STORAGE="20Gi"
# On top of setting up persistent storage for the platform Prometheus, we are
# also annotating the PVCs so that the cluster-monitoring-operator can delete
# the PVC if needed to prevent single point of failure. This is required to
# prevent the operator from reporting Upgradeable=false.
cat >> "${PATCH}" << EOF
prometheusK8s:
  volumeClaimTemplate:
    metadata:
      name: prometheus-data
      annotations:
        openshift.io/cluster-monitoring-drop-pvc: "yes"
    spec:
      resources:
        requests:
          storage: ${STORAGE}
EOF

CONFIG_CONTENTS="$(echo "${CONFIG_CONTENTS}" | yq-go m - "${PATCH}")"
yq-go w --style folded -i "${PROMETHEUS_CONFIG}" 'data."config.yaml"' "${CONFIG_CONTENTS}"
cat "${PROMETHEUS_CONFIG}"

# -------------------------------------------------------------------------------------
# Create cluster
# -------------------------------------------------------------------------------------
total=$(cat $MASTER_INSTANCE_TYPE_LIST | wc -l)
i=0
while IFS= read -r master_instance_type; do
    set +o errexit
    let i+=1

    cluster_name=$(get_cluster_name "${master_instance_type}")
    install_dir=$(get_install_dir "${master_instance_type}")
    worker_instance_type="$(yq-go r ${INSTANCE_TYPE_LIST} "(master==${master_instance_type}).worker")"    
    region="$(yq-go r ${INSTANCE_TYPE_LIST} "(master==${master_instance_type}).region")"
    mkdir -p ${install_dir}

    echo "================================================================"
    echo "Creating cluster [master:${master_instance_type}][worker:${worker_instance_type}][region:${region}][${cluster_name}], ${i}/${total}"
    echo "================================================================"

    create_install_config $master_instance_type $worker_instance_type $region $cluster_name $install_dir

    # create manifests
    openshift-install create manifests --dir ${install_dir} &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))
    if [ $install_ret -ne 0 ]; then
      echo "Failed tio create manifests ... "
      report_install_result "${master_instance_type}" "FAIL"
      continue
    fi

    # configure pv for prometheus to test storage 
    cp ${PROMETHEUS_CONFIG} ${install_dir}/manifests 

    # create ignition configs
    openshift-install create ignition-configs --dir ${install_dir} &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))
    if [ $install_ret -ne 0 ]; then
      echo "Failed to ignition configs ... "
      report_install_result "${master_instance_type}" "FAIL"
      continue
    else
      echo "Created ignition configs, saving infraid ... "

      infra_id="$(cat ${install_dir}/metadata.json | jq -r '.infraID')"
      cat <<< "$(jq --arg i ${infra_id} --arg master_instance_type ${master_instance_type} '.[$master_instance_type].infra_id = $i' "${RESULT}")" > ${RESULT}
    fi

    # create cluster
    openshift-install create cluster --dir ${install_dir} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))

    if [ $install_ret -ne 0 ]; then
      report_install_result "${master_instance_type}" "FAIL"
      # skip the healthy check, destroy cluster directly
      destroy_cluster "${install_dir}"
      continue
    else
      report_install_result "${master_instance_type}" "PASS"
    fi

    echo "--- Health check ---"

    if [[ -f ${install_dir}/auth/kubeconfig ]]; then
      export KUBECONFIG=${install_dir}/auth/kubeconfig
      health_check "${master_instance_type}"
      health_ret=$?
      ret=$((ret+health_ret))

      if [ $health_ret -ne 0 ]; then
        report_health_check_result "${master_instance_type}" "FAIL"
      else
        report_health_check_result "${master_instance_type}" "PASS"
      fi
    else
      report_health_check_result "${master_instance_type}" "FAIL"
      ret=$((ret+1))
    fi

    # destroy cluster
    destroy_cluster "${install_dir}"
    set -o errexit
done < ${MASTER_INSTANCE_TYPE_LIST}

exit $ret
