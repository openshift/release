#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'post_step_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

INSTALL_BASE_DIR=/tmp/install_base_dir
mkdir -p ${INSTALL_BASE_DIR}
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
ret=0

# following regions will be tested
REGIONS_LIST=${ARTIFACT_DIR}/regions.txt
RESULT=${SHARED_DIR}/result.json
echo '{}' > ${RESULT}


function post_step_actions()
{
  set +o errexit
  pushd $INSTALL_BASE_DIR
  # find . -name metadata.json -exec cp --parents '{}' ${SHARED_DIR}  \;
  cp ${RESULT} ${ARTIFACT_DIR}/
  find . -name "log-bundle-*.tar.gz" -exec cp --parents '{}' ${ARTIFACT_DIR}  \;

  find . -name .openshift_install.log -exec cp --parents '{}' ${ARTIFACT_DIR}  \;
  find ${ARTIFACT_DIR} -name .openshift_install.log -exec sed -i 's/password: .*/password: REDACTED/; s/X-Auth-Token.*/X-Auth-Token REDACTED/; s/UserData:.*,/UserData: REDACTED,/;' '{}' \;
  popd
  set -o errexit

  echo "--- ARTIFACT_DIR ---"
  find ${ARTIFACT_DIR} -type f
  echo "--- SHARED_DIR ---"
  find ${SHARED_DIR} -type f
  echo "--- INSTALL_BASE_DIR ---"
  find ${INSTALL_BASE_DIR} -type f
  echo "--- RESULTS ---"
  echo -e "region\tcluster_name\tinfra_id\tAMI_check\tinstall\thealth_check"
  jq -r '.[] | [.region, .cluster_name, .infra_id, .is_AMI_ready, .install_result, .health_check_result] | @tsv' $RESULT
}

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

# inject_spot_instance_config is an AWS specific option that enables the
# use of AWS spot instances.
# PARAMS:
# $1: Path to base output directory of `openshift-install create manifests`
# $2: Either "workers" or "masters" to enable spot instances on the
#     compute or control machines, respectively.
function inject_spot_instance_config() {
  local dir=${1}
  local mtype=${2}

  # Find manifest files
  local manifests=
  case "${mtype}" in
    masters)
      manifests="${dir}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml \
        ${dir}/openshift/99_openshift-cluster-api_*-machines-*.yaml"
      # Spot masters works for
      # - CAPA, always -- discover by existence of the cluster-api directory
      # - Terraform, only for newer installer binaries containing https://github.com/openshift/installer/pull/8349
      if [[ -d ${dir}/cluster-api/machines ]]; then
        echo "Spot masters supported via CAPA"
        manifests="${dir}/cluster-api/machines/10_inframachine_*.yaml $manifests"
      elif openshift-install list-hidden-features 2>/dev/null | grep -q terraform-spot-masters; then
        echo "Spot masters supported via terraform"
      else
        echo "Spot masters are not supported in this configuration!"
        return 1
      fi
      ;;
    workers)
      manifests="${dir}/openshift/99_openshift-cluster-api_*-machineset-*.yaml"
      ;;
    *)
      echo "ERROR: Invalid machine type '$mtype' passed to inject_spot_instance_config; expected 'masters' or 'workers'"
      return 1
      ;;
  esac

  # Inject spotMarketOptions into the appropriate manifests
  local prefix=
  # local found=false
  # Don't rely on file names; iterate through all the manifests and match
  # by kind.
  for manifest in $manifests; do
    # E.g, CPMS is not present for single node clusters
    if [[ ! -f ${manifest} ]]; then
      continue
    fi
    kind=$(yq-go r "${manifest}" kind)
    case "${kind}" in
      MachineSet)  # Workers, both tf and CAPA, run through MachineSet today.
          [[ "${mtype}" == "workers" ]] || continue
          prefix='spec.template.spec.providerSpec.value'
          ;;
      AWSMachine)  # CAPA masters
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec'
          ;;
      Machine)  # tf masters during install
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec.providerSpec.value'
          ;;
      ControlPlaneMachineSet)  # masters reconciled after install
          [[ "${mtype}" == "masters" ]] || continue
          prefix='spec.template.machines_v1beta1_machine_openshift_io.spec.providerSpec.value'
          ;;
      *)
          continue
          ;;
    esac
    # found=true
    echo "Using spot instances for ${kind} in ${manifest}"
    yq-go w -i --tag '!!str' "${manifest}" "${prefix}.spotMarketOptions.maxPrice" ''
  done

  # if $found; then
  #   echo "Enabled AWS Spot instances for ${mtype}"
  # else
  #   echo "ERROR: Spot instances were requested for ${mtype}, but no such manifests were found!"
  #   return 1
  # fi
}

function generate_regions()
{
  if [[ ${CUSTOM_REGION_LIST} == "" ]]; then
    # Get all regions
    aws --region $LEASED_RESOURCE ec2 describe-regions > ${ARTIFACT_DIR}/all_regions.json
    jq -r '.Regions[] | select(.OptInStatus=="opted-in" or .OptInStatus=="opt-in-not-required") | .RegionName' ${ARTIFACT_DIR}/all_regions.json | sort > ${REGIONS_LIST}

    if [[ ${REGIONS_IGNORED} != "" ]]; then
      echo "Following regions will be ignored: ${REGIONS_IGNORED}"
      for r in $REGIONS_IGNORED;
      do
        sed -i "/^${r}$/d" $REGIONS_LIST
      done
    fi

    # Split regions
    if [[ ${SPILT_REGIONS} != "" ]]; then
      echo "Spliting regions into 2 parts ..."
      pushd /tmp/
      total_region_count=$(cat $REGIONS_LIST | wc -l)
      each_part_count=$((${total_region_count}/2+1))
      echo "SPILT_REGIONS: ${SPILT_REGIONS}, total: ${total_region_count}, each: ${each_part_count}"

      split -l${each_part_count} $REGIONS_LIST
      ls xa*

      case "${SPILT_REGIONS}" in
        REGION_SET_A)
          cp xaa $REGIONS_LIST
          ;;
        REGION_SET_B)
          cp xab $REGIONS_LIST
          ;;
        *)
          echo "ERROR: Unsuported SPILT_REGIONS: ${SPILT_REGIONS}"
          exit 1
          ;;
      esac
      popd
    fi
  else
    echo "CUSTOM_REGION_LIST is provided: ${CUSTOM_REGION_LIST}"
    echo ${CUSTOM_REGION_LIST} | sed 's/ /\n/g' > ${REGIONS_LIST}
  fi
}

function get_cluster_name()
{
  local region=$1
  echo "${NAMESPACE}-${UNIQUE_HASH}-$(echo ${region} | md5sum | cut -c1-3)"
}

function get_install_dir()
{
  local region=$1
  echo "${INSTALL_BASE_DIR}/$(get_cluster_name $region)"
}

function create_install_config()
{
  local region=$1
  local cluster_name=$2
  local install_dir=$3

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: ${OCP_ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 2
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
    region: ${region}
publish: External
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

  local az
  az=$(aws ec2 --region $region describe-availability-zones --filters Name=zone-type,Values=availability-zone Name=opt-in-status,Values=opt-in-not-required | jq -r '.AvailabilityZones[0].ZoneName')
  if ! is_empty "$az"; then
    cat > "${patch}" << EOF
controlPlane:
  platform:
    aws:
      zones: [${az}]
compute:
- platform:
    aws:
      zones: [${az}]
EOF
      yq-go m -x -i ${install_dir}/install-config.yaml "${patch}"
  fi
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

function report_install_result()
{
  local region=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: INSTALL: ${region} $(get_cluster_name $region)"
  cat <<< "$(jq --arg region ${region} --arg m ${fail_or_pass} '.[$region].install_result = $m' "${RESULT}")" > ${RESULT}
}

function report_health_check_result()
{
  local region=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: HEALTH CHECK: ${region} $(get_cluster_name $region)"
  cat <<< "$(jq --arg region ${region} --arg m ${fail_or_pass} '.[$region].health_check_result = $m' "${RESULT}")" > ${RESULT}
}

function report_amiid_result()
{
  local region=$1
  local fail_or_pass=$2
  echo ">>> ${fail_or_pass}: AMI ID CHECK: ${region} $(get_cluster_name $region)"
  cat <<< "$(jq --arg region ${region} --arg m ${fail_or_pass} '.[$region].is_AMI_ready = $m' "${RESULT}")" > ${RESULT}
}


# -------------------------------------------------------------------------------------
# generate regions
# -------------------------------------------------------------------------------------
echo "Getting regions for test ..."
generate_regions
echo "Following regions will be tested:"
cat ${REGIONS_LIST}

# -------------------------------------------------------------------------------------
# init result file
# -------------------------------------------------------------------------------------
echo "Creating result file ..."
t=$(mktemp)
while IFS= read -r region; do
    cat > ${t} << EOF
{
  "region": "${region}",
  "cluster_name": "$(get_cluster_name "${region}")",
  "install_dir": "$(get_install_dir "${region}")",
  "infra_id": "NA",
  "install_result": "NA",
  "health_check_result": "NA",
  "is_AMI_ready": "NA",
  "destroy_result": "NA",
  "metadata": ""
}
EOF
    cat <<< "$(jq  --argjson info "$(<${t})" --arg region $region '. += {($region): $info}' "${RESULT}")" > ${RESULT}
done < ${REGIONS_LIST}

# -------------------------------------------------------------------------------------
# Create cluster
# -------------------------------------------------------------------------------------
total=$(cat $REGIONS_LIST | wc -l)
i=0
while IFS= read -r region; do
    set +o errexit
    let i+=1
    # init result
    cluster_name=$(get_cluster_name "${region}")
    install_dir=$(get_install_dir "${region}")
    mkdir -p ${install_dir}

    echo "================================================================"
    echo "Creating cluster [${region}][${cluster_name}], ${i}/${total}"
    echo "================================================================"

    # checking if AMI is ready
    ami_exist=0
    for ARCH in aarch64 x86_64;
    do
      
      amiid=$(openshift-install coreos print-stream-json | jq -r --arg a $ARCH --arg r $region '.architectures[$a].images.aws.regions[$r].image')
      echo "AMI id $region $ARCH: $amiid"
      if is_empty "$amiid"; then
        ami_exist=1
      fi
    done

    if [[ "${ami_exist}" == "0" ]]; then
      report_amiid_result "${region}" "PASS"
    else
      report_amiid_result "${region}" "FAIL"
    fi

    create_install_config $region $cluster_name $install_dir

    # create manifests
    openshift-install create manifests --dir ${install_dir} &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))
    if [ $install_ret -ne 0 ]; then
      echo "Failed tio create manifests, saving metadata.json ... "
      report_install_result "${region}" "FAIL"
      continue
    fi


    # Spot instances
    if [[ "${SPOT_INSTANCES:-}"  == 'true' ]]; then
      echo "Enabling Spot instances on compute nodes ... "
      inject_spot_instance_config "${install_dir}" "workers"
    fi
    if [[ "${SPOT_MASTERS:-}" == 'true' ]]; then
      echo "Enabling Spot instances on control plane nodes ... "
      inject_spot_instance_config "${install_dir}" "masters"
    fi


    # create ignition configs
    openshift-install create ignition-configs --dir ${install_dir} &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))
    if [ $install_ret -ne 0 ]; then
      echo "Failed to ignition configs, saving metadata.json ... "
      report_install_result "${region}" "FAIL"
      continue
    else
      echo "Created ignition configs, saving metadata.json and infraid ... "

      cp ${install_dir}/metadata.json ${SHARED_DIR}/metadata.${region}.json

      metadata_b64="$(cat ${install_dir}/metadata.json | base64 -w0)"
      infra_id="$(cat ${install_dir}/metadata.json | jq -r '.infraID')"
      cat <<< "$(jq --arg metadata ${metadata_b64} --arg region ${region} '.[$region].metadata = $metadata' "${RESULT}")" > ${RESULT}
      cat <<< "$(jq --arg i ${infra_id} --arg region ${region} '.[$region].infra_id = $i' "${RESULT}")" > ${RESULT}
    fi

    # create cluster
    openshift-install create cluster --dir ${install_dir} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
    wait "$!"
    install_ret="$?"
    ret=$((ret+install_ret))

    if [ $install_ret -ne 0 ]; then
      report_install_result "${region}" "FAIL"
      continue
    else
      report_install_result "${region}" "PASS"
    fi

    echo "--- Health check ---"

    if [[ -f ${install_dir}/auth/kubeconfig ]]; then
      export KUBECONFIG=${install_dir}/auth/kubeconfig
      health_check
      health_ret=$?
      ret=$((ret+health_ret))

      if [ $health_ret -ne 0 ]; then
        report_health_check_result "${region}" "FAIL"
      else
        report_health_check_result "${region}" "PASS"
      fi
    else
      report_health_check_result "${region}" "FAIL"
      ret=$((ret+1))
    fi
    set -o errexit
done < ${REGIONS_LIST}
exit $ret
