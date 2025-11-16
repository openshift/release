#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'post_actions' EXIT TERM INT

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"


echo "TEST_OBJECT: $TEST_OBJECT"
OUT_SELECT=${SHARED_DIR}/select.json
OUT_SELECT_DICT=${SHARED_DIR}/select.dict.json
OUT_RESULT=${SHARED_DIR}/result.json
echo '{}' > "$OUT_RESULT"

IC_COMPUTE_NODE_COUNT=2
IC_CONTROL_PLANE_NODE_COUNT=3

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

if [ ! -f "${OUT_SELECT}" ]; then
  echo "ERROR: Not found OUT_SELECT file."
  exit 1
fi

if [ ! -f "${OUT_SELECT_DICT}" ]; then
  echo "ERROR: Not found OUT_SELECT_DICT file."
  exit 1
fi

function current_date() { date -u +"%Y-%m-%d %H:%M:%S%z"; }

function update_result() {
  local k=$1
  local v=${2:-}
  cat <<< "$(jq -r --argjson kv "{\"$k\":\"$v\"}" '. + $kv' "$OUT_RESULT")" > "$OUT_RESULT"
}

function post_actions() {
  set +e

  current_time=$(date +%s)

  echo "Copying kubeconfig and metadata.json to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"

  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  echo "Copying install log and removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"

  # Writing result
  # "Bucket": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.bucket')",
  # "JobUrlPrefix": "$(echo "${JOB_SPEC}" | jq -r '.decoration_config.gcs_configuration.job_url_prefix')",
  
  update_result "Region" "${REGION}"
  update_result "CPType" "${CONTROL_PLANE_INSTANCE_TYPE}"
  update_result "CPamily" "${CONTROL_PLANE_INSTANCE_TYPE_FAMILY}"
  update_result "CType" "${COMPUTE_INSTANCE_TYPE}"
  update_result "CFamily" "${COMPUTE_INSTANCE_TYPE_FAMILY}"
  update_result "Arch" "${ARCH}"
  update_result "AMI" "${AMI_RESULT}"
  update_result "Install" "${INSTALL_RESULT}"
  update_result "Health" "${HEALTHCHECK_RESULT}"
  update_result "CreatedDate" "${CREATED_DATE}"
  update_result "Job" "$(echo "${JOB_SPEC}" | jq -r '.job')"
  update_result "BuildID" "$(echo "${JOB_SPEC}" | jq -r '.buildid')"
  update_result "URL" "TBD"
  update_result "RowUpdated" "$(current_date)"

  echo "RESULT:"
  jq -r . "${OUT_RESULT}"

  # save JOB_SPEC to ARTIFACT_DIR for debugging
  echo "${JOB_SPEC}" | jq -r . > ${ARTIFACT_DIR}/JOB_SPEC.json

}

# creating cluster

SSH_PUB_KEY=$(< "${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(< "${CLUSTER_PROFILE_DIR}/pull-secret")

REGION="$(jq -r '.Region' "${OUT_SELECT_DICT}")"
ARCH="$(jq -r '.Arch' "${OUT_SELECT_DICT}")"

CONTROL_PLANE_INSTANCE_TYPE="$(jq -r '.CPType' "${OUT_SELECT_DICT}")"
CONTROL_PLANE_INSTANCE_TYPE_FAMILY="$(jq -r '.CPFamily' "${OUT_SELECT_DICT}")"

COMPUTE_INSTANCE_TYPE="$(jq -r '.CType' "${OUT_SELECT_DICT}")"
COMPUTE_INSTANCE_TYPE_FAMILY="$(jq -r '.CFamily' "${OUT_SELECT_DICT}")"

if is_empty "$ARCH"; then
  # Default ARCH is determined by each plarform.
  # For most of cased, default is arm.
  # For the resgions which do not support arm64, then set amd64
  ARCH="arm64"
fi

echo "Creating cluster in region ${REGION}:"
echo "ARCH: $ARCH"
echo "CONTROL_PLANE_INSTANCE*: $CONTROL_PLANE_INSTANCE_TYPE $CONTROL_PLANE_INSTANCE_TYPE_FAMILY"
echo "COMPUTE_INSTANCE*: $COMPUTE_INSTANCE_TYPE $COMPUTE_INSTANCE_TYPE_FAMILY"

AMI_RESULT=""
INSTALL_RESULT=""
HEALTHCHECK_RESULT=""
CREATED_DATE="$(current_date)"

function create_install_config() {
  local cluster_name=$1
  local install_dir=$2

  local config
  config=${install_dir}/install-config.yaml

  cat > "${config}" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: ${ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: ${IC_COMPUTE_NODE_COUNT}
controlPlane:
  architecture: ${ARCH}
  hyperthreading: Enabled
  name: master
  platform: {}
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
platform: {}
publish: External
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
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
  oc get clusteroperator > "${tmp_clusteroperator}"
  column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
  last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
  if [[ ${last_column_name} == "MESSAGE" ]]; then
    ((column -= 1))
    tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
    awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
    input="${tmp_clusteroperator_1}"
  fi

  while IFS= read -r line; do
    rc=$(echo "${line}" | awk '{print NF}')
    if ((rc != column)); then
      echo >&2 "The following line have empty column"
      echo >&2 "${line}"
      ((tmp_ret += 1))
    fi
  done < "${input}"
  rm -f "${tmp_clusteroperator}"

  echo "Make sure every operator column reports version"
  if null_version=$(oc get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
    echo >&2 "Null Version: ${null_version}"
    ((tmp_ret += 1))
  fi

  echo "Make sure every operator reports correct version"
  if incorrect_version=$(oc get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${EXPECTED_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
    echo >&2 "Incorrect CO Version: ${incorrect_version}"
    ((tmp_ret += 1))
  fi

  echo "Make sure every operator's AVAILABLE column is True"
  if unavailable_operator=$(oc get clusteroperator | awk '$3 == "False"' | grep "False"); then
    echo >&2 "Some operator's AVAILABLE is False"
    echo >&2 "$unavailable_operator"
    ((tmp_ret += 1))
  fi
  if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
    echo >&2 "Some operators are not Available, pls run 'oc get clusteroperator -o json' to check"
    ((tmp_ret += 1))
  fi

  echo "Make sure every operator's PROGRESSING column is False"
  if progressing_operator=$(oc get clusteroperator | awk '$4 == "True"' | grep "True"); then
    echo >&2 "Some operator's PROGRESSING is True"
    echo >&2 "$progressing_operator"
    ((tmp_ret += 1))
  fi
  if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
    echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
    ((tmp_ret += 1))
  fi

  echo "Make sure every operator's DEGRADED column is False"
  if degraded_operator=$(oc get clusteroperator | awk '$5 == "True"' | grep "True"); then
    echo >&2 "Some operator's DEGRADED is True"
    echo >&2 "$degraded_operator"
    ((tmp_ret += 1))
  fi
  if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status' | grep -iv 'False'; then
    echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
    ((tmp_ret += 1))
  fi

  return $tmp_ret
}

function wait_clusteroperators_continous_success() {
  local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20
  while ((try < max_retries && continous_successful_check < passed_criteria)); do
    echo "Checking #${try}"
    if check_clusteroperators; then
      echo "Passed #${continous_successful_check}"
      ((continous_successful_check += 1))
    else
      echo "cluster operators are not ready yet, wait and retry..."
      continous_successful_check=0
    fi
    sleep 60
    ((try += 1))
  done
  if ((continous_successful_check != passed_criteria)); then
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
  if [[ -s ${tmp_output} ]]; then
    updating_mcp=$(cat "${tmp_output}" | grep -v "False")
    if [[ -n ${updating_mcp} ]]; then
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
  if [[ -s ${tmp_output} ]]; then
    unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
    if [[ -n ${unhealthy_mcp} ]]; then
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
        oc describe mcp "$mcp_name" || echo "oc describe mcp $mcp_name failed"
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
  local try=0 continous_successful_check=0 passed_criteria=5 max_retries=20 tmp_ret=0
  local continous_degraded_check=0 degraded_criteria=5
  while ((try < max_retries && continous_successful_check < passed_criteria)); do
    echo "Checking #${try}"
    tmp_ret=0
    check_mcp || tmp_ret=$?
    if [[ $tmp_ret == "0" ]]; then
      continous_degraded_check=0
      echo "Passed #${continous_successful_check}"
      ((continous_successful_check += 1))
    elif [[ $tmp_ret == "1" ]]; then
      echo "Some machines are updating..."
      continous_successful_check=0
      continous_degraded_check=0
    else
      continous_successful_check=0
      echo "Some machines are degraded #${continous_degraded_check}..."
      ((continous_degraded_check += 1))
      if ((continous_degraded_check >= degraded_criteria)); then
        break
      fi
    fi
    echo "wait and retry..."
    sleep 60
    ((try += 1))
  done
  if ((continous_successful_check != passed_criteria)); then
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
  if ((node_number == ready_number)); then
    echo "All nodes status check PASSED"
    return 0
  else
    if ((ready_number == 0)); then
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

  soptted_pods=$(oc get pod --all-namespaces | grep -Evi "running|Completed" | grep -v NAMESPACE)
  if [[ -n $soptted_pods ]]; then
    echo "There are some abnormal pods:"
    echo "${soptted_pods}"
  fi
  echo "Show all pods for reference/debug"
  run_command "oc get pods --all-namespaces"
}

function all_nodes() {

  local node_ret
  node_ret=0

  local machines_json nodes_json
  machines_json=${ARTIFACT_DIR}/machines.json
  nodes_json=${ARTIFACT_DIR}/nodes.json
  oc get machines.machine.openshift.io -n openshift-machine-api -ojson > "$machines_json"
  oc get node -ojson > "$nodes_json"

  oc get machines.machine.openshift.io -n openshift-machine-api -owide
  oc get node -owide

  local control_plane_node_count compute_node_count
  control_plane_node_count=$(jq -r '.items | map(select(.metadata.labels."node-role.kubernetes.io/master"?)) | length' "${nodes_json}")
  compute_node_count=$(jq -r '.items | map(select(.metadata.labels."node-role.kubernetes.io/worker"? and (.metadata.labels."node-role.kubernetes.io/edge"? | not))) | length' "${nodes_json}")

  echo "control_plane_node_count: ${control_plane_node_count}, except: ${IC_CONTROL_PLANE_NODE_COUNT}"
  echo "compute_node_count: ${compute_node_count}, except: ${IC_COMPUTE_NODE_COUNT}"

  if [[ ${control_plane_node_count} != "${IC_CONTROL_PLANE_NODE_COUNT}" ]]; then
    node_ret=$((node_ret + 1))
  fi

  if [[ ${compute_node_count} != "${IC_COMPUTE_NODE_COUNT}" ]]; then
    node_ret=$((node_ret + 1))
  fi

  if [ "${TEST_OBJECT}" == "LocalZones" ] || [ "${TEST_OBJECT}" == "WavelengthZones" ]; then

    # total
    local edge_node_count
    IC_EDGE_NODE_COUNT=$(jq -r --arg t "${EDGE_ZONE_TYPE}" '[.AvailabilityZones[] | select(.ZoneType==$t)] | length' "${ZONES_JSON}")
    edge_node_count=$(jq -r '.items | map(select(.metadata.labels."node-role.kubernetes.io/edge"?)) | length' "${nodes_json}")
    echo "edge_node_count: ${edge_node_count}, except: ${IC_EDGE_NODE_COUNT}"

    if [[ ${edge_node_count} != "${IC_EDGE_NODE_COUNT}" ]]; then
      node_ret=$((node_ret + 1))
    fi

    # each edge zone
    local edge_zones
    local c
    edge_zones=$(jq -r --arg t "${EDGE_ZONE_TYPE}" '.AvailabilityZones[] | select(.ZoneType==$t) | .ZoneName' "${ZONES_JSON}")
    for edge_zone in ${edge_zones}; do
      c=$(jq -r --arg z "${edge_zone}" '[.items[] | select(.spec.providerID | contains($z))] | length' "${nodes_json}")
      echo "edge zone: ${edge_zone}, count: $c"
      if ((c != 1)); then
        node_ret=$((node_ret + 1))
      fi
    done
  fi
  return ${node_ret}
}

function check_node_count() {
  local try=1
  local total=30
  local interval=60
  while [[ ${try} -le ${total} ]]; do
    echo "Check nodes status (try ${try} / ${total})"

    if ! all_nodes; then
      sleep ${interval}
      ((try++))
      continue
    else
      echo "Nodes count is expected."
      return 0
    fi
  done
  return 1
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

  echo "Step #5: check node count"
  check_node_count || return 1
}

ret=0

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
INSTALL_DIR=/tmp/install_dir
mkdir -p ${INSTALL_DIR}

# ---------------------------------------
# Print openshift-install version
# ---------------------------------------

openshift-install version

# ---------------------------------------
# Pre-checks
# ---------------------------------------

echo "--- Check AMI ---"

if [ "$ARCH" == "amd64" ]; then
  ami_arch="x86_64"
elif [ "$ARCH" == "arm64" ]; then
  ami_arch="aarch64"
fi

set +e
amiid=$(openshift-install coreos print-stream-json | jq -r --arg a "$ami_arch" --arg r "$REGION" '.architectures[$a].images.aws.regions[$r].image')
set -e

echo "AMI architecture: ${ami_arch}, region: ${REGION}"

if is_empty "$amiid"; then
  AMI_RESULT="FAIL"
else
  AMI_RESULT="PASS"
fi

# ---------------------------------------
# Create install-config
# ---------------------------------------

echo "--- Create install-config ---"

create_install_config "${CLUSTER_NAME}" "${INSTALL_DIR}"
CONFIG="${INSTALL_DIR}"/install-config.yaml

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred

ZONES_JSON=/tmp/zones.json
aws --region "$REGION" ec2 describe-availability-zones --filters Name=opt-in-status,Values=opted-in,opt-in-not-required > ${ZONES_JSON}

# Patch region
export REGION
yq-v4 eval -i '.platform.aws.region = env(REGION)' "${CONFIG}"

# Patch ARCH
if [ "${ARCH}" == "" ]; then
  yq-v4 eval -i '.controlPlane.architecture = "amd64"' "${CONFIG}"
  yq-v4 eval -i '.controlPlane.architecture = "amd64"' "${CONFIG}"
else
  export ARCH
  yq-v4 eval -i '.controlPlane.architecture = env(ARCH)' "${CONFIG}"
  yq-v4 eval -i '.controlPlane.architecture = env(ARCH)' "${CONFIG}"
fi

# Patch instance type
if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
  export CONTROL_PLANE_INSTANCE_TYPE
  yq-v4 eval -i '.controlPlane.platform.aws.type = env(CONTROL_PLANE_INSTANCE_TYPE)' "${CONFIG}"
fi
if [[ ${COMPUTE_INSTANCE_TYPE} != "" ]]; then
  export COMPUTE_INSTANCE_TYPE
  yq-v4 eval -i '.compute[0].platform.aws.type = env(COMPUTE_INSTANCE_TYPE)' "${CONFIG}"
fi

# Patch AZ, only use one AZ to reduce EIP usage
if [ "$TEST_OBJECT" == "InstanceTypes" ];  then
  # check the instance type offering
  
  t1=$(mktemp)
  t2=$(mktemp)
  aws --region "$REGION" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="$CONTROL_PLANE_INSTANCE_TYPE" --query 'InstanceTypeOfferings[*].Location' | jq -r '.[]' | sort > "$t1"
  aws --region "$REGION" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="$COMPUTE_INSTANCE_TYPE" --query 'InstanceTypeOfferings[*].Location' | jq -r '.[]' | sort > "$t2"
  ZONE_NAME=$(comm -12 "$t1" "$t2" | head -n 1)
  if [ "$ZONE_NAME" == "" ]; then
    echo "ERROR: Can not find an Availability Zone that provides both $CONTROL_PLANE_INSTANCE_TYPE and $COMPUTE_INSTANCE_TYPE"
    exit 1
  fi
else
  # select the first one
  ZONE_NAME=$(jq -r '[.AvailabilityZones[] | select(.ZoneType=="availability-zone")] | .[0].ZoneName' "${ZONES_JSON}")
fi

export ZONE_NAME
yq-v4 eval -i '.controlPlane.platform.aws.zones += [env(ZONE_NAME)]' "${CONFIG}"
yq-v4 eval -i '.compute[0].platform.aws.zones += [env(ZONE_NAME)]' "${CONFIG}"

# Patch Edge nodes
if [ "${TEST_OBJECT}" == "LocalZones" ] || [ "${TEST_OBJECT}" == "WavelengthZones" ]; then

  # patch edge node
  EDGE_ZONES_JSON=/tmp/edge_zones.json
  if [ "${TEST_OBJECT}" == "LocalZones" ]; then
    EDGE_ZONE_TYPE="local-zone"
  fi
  if [ "${TEST_OBJECT}" == "WavelengthZones" ]; then
    EDGE_ZONE_TYPE="wavelength-zone"
  fi

  jq -r -arg t "$ZONE_TYPE" '[.AvailabilityZones[] | select(.ZoneType==$t)]' "${ZONES_JSON}" > "${EDGE_ZONES_JSON}"

  EDGE_ZONE_COUNT=$(jq -r '. | length' ${EDGE_ZONES_JSON})
  EDGE_ZONE_NAMES=$(jq -r '.[].ZoneName' ${EDGE_ZONES_JSON})

  if [ "${ARCH}" == "" ]; then
    yq-v4 eval -i '.compute[1].architecture = "amd64"' "${CONFIG}"
  else
    export ARCH
    yq-v4 eval -i '.compute[1].architecture = env(ARCH)' "${CONFIG}"
  fi

  yq-v4 eval -i '.compute[1].hyperthreading = "Enabled"' "${CONFIG}"
  yq-v4 eval -i '.compute[1].name = "edge"' "${CONFIG}"
  export EDGE_ZONE_COUNT
  yq-v4 eval -i '.compute[1].replicas = env(EDGE_ZONE_COUNT)' "${CONFIG}"
  for edge_zone in ${EDGE_ZONE_NAMES}; do
    export edge_zone
    yq-v4 eval -i '.compute[1].platform.aws.zones += [env(edge_zone)]' "${CONFIG}"
    unset edge_zone
  done
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"

# ---------------------------------------

echo "--- Create manifests ---"

set +e
openshift-install create manifests --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to create manifests. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created manifests."
fi

# ---------------------------------------

echo "--- Create ignition configs ---"

set +e
openshift-install create ignition-configs --dir ${INSTALL_DIR} &
wait "$!"
install_ret="$?"
set -e

ret=$((ret + install_ret))
if [ $install_ret -ne 0 ]; then
  echo "Failed to ignition configs. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created ignition configs."
fi

# ---------------------------------------

echo "--- Create cluster ---"

set +e
openshift-install create cluster --dir ${INSTALL_DIR} 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
install_ret="$?"
set -e

if [ $install_ret -ne 0 ]; then
  echo "Failed to create clusters. Exit code: $install_ret"
  INSTALL_RESULT="FAIL"
else
  echo "Created cluster."
  INSTALL_RESULT="PASS"
fi
ret=$((ret + install_ret))

# ---------------------------------------
# Health check
# ---------------------------------------

echo "--- Health check ---"
if [ $install_ret -eq 0 ]; then

  if [[ -f ${INSTALL_DIR}/auth/kubeconfig ]]; then
    export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

    health_check_ret=0

    set +e
    health_check "${REGION}"
    set -e

    health_check_ret="$?"
    
    if [ $health_check_ret -ne 0 ]; then
      echo "Healthcheck failed."
      HEALTHCHECK_RESULT="FAIL"
      ret=$((ret + 1))
    else
      echo "Healthcheck succeeded."
      HEALTHCHECK_RESULT="PASS"
    fi
  else
    echo "No kubeconfig found."
    ret=$((ret + 1))
  fi
else
  echo "Install FAIL, skip health check."
  HEALTHCHECK_RESULT="FAIL"
fi


# ---------------------------------------
# Gather must-gather
# ---------------------------------------

if [ "$INSTALL_RESULT" == "FAIL" ] && grep -q "Bootstrap status: complete" ${INSTALL_DIR}/.openshift_install.log; then
  if [[ -f ${INSTALL_DIR}/auth/kubeconfig ]]; then
    set +e

    echo "Getting must-gather logs ..."
    export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
    pushd "${INSTALL_DIR}"    
    oc adm must-gather
    latest_gather=$(find . -maxdepth 1 -type d -name "must-gather*" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    tar zcf ${ARTIFACT_DIR}/must-gather.tar.gz  ${latest_gather}
    echo "Created must-gather.tar.gz"
    popd

    set -e
  fi
fi

echo "ret: $ret"
exit $ret
