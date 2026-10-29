#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Version comparison helper using sort -V
function version_ge() {
  # Returns 0 (true) if $1 >= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CONFIG=${SHARED_DIR}/install-config.yaml
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

function has_tags() {
  local txt="$1"
  if grep -qiE "TAGS.*kubernetes.io/cluster/${INFRA_ID}" "$txt"; then
    return 0
  fi
  return 1
}

function has_shared_tags() {
  local txt="$1"
  if grep -qiE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*shared" "$txt"; then
    return 0
  fi
  return 1
}

# has_owned_tags reports whether the resource carries the installer ownership tag
# kubernetes.io/cluster/${INFRA_ID}: owned, which the installer attaches to the
# IAM roles it creates itself (as opposed to BYO roles, which get "shared").
function has_owned_tags() {
  local txt="$1"
  if grep -qiE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*owned" "$txt"; then
    return 0
  fi
  return 1
}

# verify_installer_default_role checks that a pool with no BYO role falls back to
# the installer-generated default: the role must exist under the expected
# installer name, be the one actually attached to the pool's nodes, and carry the
# installer ownership tag rather than the BYO "shared" tag.
# args: <pool label> <role attached to nodes> <expected installer default role> <get-role output file>
function verify_installer_default_role() {
  local label="$1" actual_role="$2" default_role="$3" role_output="$4"
  local probe_output
  probe_output=$(mktemp)

  # Confirm the role exists via the API using the command's exit status rather
  # than matching an error message string. On failure, the stable NoSuchEntity
  # error code distinguishes genuine absence from other query errors.
  if aws --region "$REGION" iam get-role --role-name "${default_role}" > "${probe_output}" 2>&1; then
    echo "PASS: ${label}: installer default role ${default_role} exists."
  elif grep -q "NoSuchEntity" "${probe_output}"; then
    echo "FAIL: ${label}: installer default role ${default_role} does not exist."
    ret=$((ret+1))
  else
    echo "FAIL: ${label}: error querying installer default role ${default_role}:"
    cat "${probe_output}"
    ret=$((ret+1))
  fi
  rm -f "${probe_output}"

  if [[ "${actual_role}" != "${default_role}" ]]; then
    echo "FAIL: ${label}: IAM role mismatch: current: ${actual_role}, expected installer default: ${default_role}"
    ret=$((ret+1))
  else
    echo "PASS: ${label}: using installer default IAM role ${actual_role}"
  fi

  # Installer-owned roles carry kubernetes.io/cluster/<infra>: owned; a BYO role
  # would instead carry the shared tag.
  if has_owned_tags "${role_output}"; then
    echo "PASS: ${label}: tag check: ${actual_role} is installer-owned"
  else
    echo "FAIL: ${label}: tag check: ${actual_role} is missing kubernetes.io/cluster/${INFRA_ID}: owned"
    ret=$((ret+1))
  fi

  if has_shared_tags "${role_output}"; then
    echo "FAIL: ${label}: IAM role ${actual_role} carries the BYO 'shared' tag; expected installer default."
    ret=$((ret+1))
  fi
}

# check_role_tag verifies the shared tag expectation for a BYO role output file.
# for 4.16 and above, shared tag is attached to BYO-Role, see https://github.com/openshift/installer/pull/8688
# for 4.15 and below, no tag is attached to BYO-Role
function check_role_tag() {
  local role_name="$1" role_output="$2"
  if version_ge "${ocp_version}" "4.16"; then
    if ! has_shared_tags "${role_output}"; then
      echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${role_name}"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${role_name}"
    fi
  else
    if has_tags "${role_output}"; then
      echo "FAIL: tag check: ${role_name}: kubernetes.io/cluster/${INFRA_ID} tag was attached"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${role_name}"
    fi
  fi
}

ret=0
output=$(mktemp)

# ocp_version is the running cluster's version, taken from the ClusterVersion resource.
ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f1,2)

echo "-------------------------------------------------------------"
echo "Roles used by cluster"
echo "-------------------------------------------------------------"

control_plane_profile=$(aws --region "$REGION" ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')
compute_profile=$(aws --region "$REGION" ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')

control_plane_role=$(aws --region "$REGION" iam get-instance-profile --instance-profile-name "${control_plane_profile}" | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $NF}')
compute_role=$(aws --region "$REGION" iam get-instance-profile --instance-profile-name "${compute_profile}" | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $NF}')

control_plane_role_output=$(mktemp)
compute_role_output=$(mktemp)

aws --region "$REGION" iam get-role --role-name "${control_plane_role}" --output text >"$control_plane_role_output"
aws --region "$REGION" iam get-role --role-name "${compute_role}" --output text >"$compute_role_output"

echo "Control plane: profile: ${control_plane_profile}, role: ${control_plane_role}"
echo "Compute:       profile: ${compute_profile}, role: ${compute_role}"

# Edge compute pool nodes (AWS Local/Wavelength zones) carry the
# node-role.kubernetes.io/edge label. Discover them by label rather than by an
# assumed instance Name tag.
edge_instance_ids=$(oc get nodes -l node-role.kubernetes.io/edge -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ 'NF{print $NF}')
edge_profile=""
edge_role=""
edge_role_output=$(mktemp)
if [[ -n "${edge_instance_ids}" ]]; then
  # shellcheck disable=SC2086 # intentional word splitting: pass each instance ID as a separate argument
  edge_profile=$(aws --region "$REGION" ec2 describe-instances --instance-ids ${edge_instance_ids} | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')
  edge_role=$(aws --region "$REGION" iam get-instance-profile --instance-profile-name "${edge_profile}" | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $NF}')
  aws --region "$REGION" iam get-role --role-name "${edge_role}" --output text >"$edge_role_output"
  echo "Edge:          profile: ${edge_profile}, role: ${edge_role}"
fi

echo "-------------------------------------------------------------"
echo "Roles configured in install-config.yaml"
echo "-------------------------------------------------------------"

ic_platform_role=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamRole')
ic_control_plane_role=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamRole')
ic_compute_role=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamRole')
# The edge pool is a named compute entry (compute[name=edge]); select it by name.
ic_edge_role=$(yq-v4 '.compute[] | select(.name == "edge").platform.aws.iamRole' "${CONFIG}")
# Detect whether an edge pool exists at all, so defaultMachinePlatform is only
# treated as an edge expectation when there is an edge pool to apply it to.
ic_edge_pool=$(yq-v4 '.compute[] | select(.name == "edge").name' "${CONFIG}")
echo "Install config: platform: ${ic_platform_role}, control plane: ${ic_control_plane_role}, compute: ${ic_compute_role}, edge: ${ic_edge_role}"

echo "-------------------------------------------------------------"
echo "Expected roles"
echo "-------------------------------------------------------------"

expected_control_plane_role=""
expected_compute_role=""
expected_edge_role=""

# defaultMachinePlatform applies to every pool, including edge, unless overridden.
# It only implies an edge expectation when an edge pool actually exists.
if ! is_empty "$ic_platform_role"; then
  echo "platform.aws.defaultMachinePlatform.iamRole was found: ${ic_platform_role}"
  expected_control_plane_role="${ic_platform_role}"
  expected_compute_role="${ic_platform_role}"
  if ! is_empty "$ic_edge_pool"; then
    expected_edge_role="${ic_platform_role}"
  fi
fi

if ! is_empty "$ic_control_plane_role"; then
  echo "controlPlane.platform.aws.iamRole was found: ${ic_control_plane_role}"
  expected_control_plane_role="${ic_control_plane_role}"
fi

if ! is_empty "$ic_compute_role"; then
  echo "compute[0].platform.aws.iamRole was found: ${ic_compute_role}"
  expected_compute_role="${ic_compute_role}"
fi

if ! is_empty "$ic_edge_role"; then
  echo "compute[name=edge].platform.aws.iamRole was found: ${ic_edge_role}"
  expected_edge_role="${ic_edge_role}"
fi

echo "expected_control_plane_role: $expected_control_plane_role"
echo "expected_compute_role: $expected_compute_role"
echo "expected_edge_role: $expected_edge_role"

echo "-------------------------------------------------------------"
echo "Checking role: control plane"
echo "-------------------------------------------------------------"

if [[ ${expected_control_plane_role} != "" ]]; then

  role_name=${INFRA_ID}-master-role
  # A BYO role is configured, so the installer must not create its default role.
  # Inspect the lookup exit status: success means the default role exists
  # (unexpected), NoSuchEntity means it is absent (expected), and any other
  # failure is a query error that cannot be classified.
  if aws --region "$REGION" iam get-role --role-name "${role_name}" > "${output}" 2>&1; then
    echo "FAIL: ${role_name} was found; expected only the BYO role."
    ret=$((ret+1))
  elif grep -q "NoSuchEntity" "${output}"; then
    echo "PASS: ${role_name} does not exist."
  else
    echo "FAIL: error querying ${role_name}:"
    cat "${output}"
    ret=$((ret+1))
  fi

  if [[ "${control_plane_role}" != "${expected_control_plane_role}" ]]; then
    echo "FAIL: Control plane IAM role mismatch: current: ${control_plane_role}, expect: ${expected_control_plane_role}"
    ret=$((ret+1))
  else
    echo "PASS: Control plane IAM role"
  fi

  check_role_tag "${control_plane_role}" "${control_plane_role_output}"

else
  # No BYO role configured; verify the control plane uses the installer default.
  verify_installer_default_role "control plane" "${control_plane_role}" "${INFRA_ID}-master-role" "${control_plane_role_output}"
fi

echo "-------------------------------------------------------------"
echo "Checking role: compute"
echo "-------------------------------------------------------------"

if [[ ${expected_compute_role} != "" ]]; then

  role_name=${INFRA_ID}-worker-role
  if aws --region "$REGION" iam get-role --role-name "${role_name}" > "${output}" 2>&1; then
    echo "FAIL: ${role_name} was found; expected only the BYO role."
    ret=$((ret+1))
  elif grep -q "NoSuchEntity" "${output}"; then
    echo "PASS: ${role_name} does not exist."
  else
    echo "FAIL: error querying ${role_name}:"
    cat "${output}"
    ret=$((ret+1))
  fi

  if [[ "${compute_role}" != "${expected_compute_role}" ]]; then
    echo "FAIL: Compute IAM role mismatch: current: ${compute_role}, expect: ${expected_compute_role}"
    ret=$((ret + 1))
  else
    echo "PASS: Compute IAM role"
  fi

  check_role_tag "${compute_role}" "${compute_role_output}"

else
  # No BYO role configured; verify the compute pool uses the installer default.
  verify_installer_default_role "compute" "${compute_role}" "${INFRA_ID}-worker-role" "${compute_role_output}"
fi

echo "-------------------------------------------------------------"
echo "Checking role: edge"
echo "-------------------------------------------------------------"

if [[ ${expected_edge_role} != "" ]]; then

  if [[ -z "${edge_instance_ids}" ]]; then
    echo "FAIL: expected edge IAM role ${expected_edge_role} but no edge nodes (node-role.kubernetes.io/edge) were found."
    ret=$((ret+1))
  else
    if [[ "${edge_role}" != "${expected_edge_role}" ]]; then
      echo "FAIL: Edge IAM role mismatch: current: ${edge_role}, expect: ${expected_edge_role}"
      ret=$((ret + 1))
    else
      echo "PASS: Edge IAM role"
    fi

    check_role_tag "${edge_role}" "${edge_role_output}"
  fi

elif ! is_empty "$ic_edge_pool"; then

  # An edge pool exists but no BYO IAM role was configured for it, so the edge
  # nodes must fall back to the installer-generated default role. The edge pool
  # gets its own role named ${INFRA_ID}-edge-role (see openshift/installer#10836).
  if [[ -z "${edge_instance_ids}" ]]; then
    echo "FAIL: edge pool is configured but no edge nodes (node-role.kubernetes.io/edge) were found."
    ret=$((ret+1))
  else
    verify_installer_default_role "edge" "${edge_role}" "${INFRA_ID}-edge-role" "${edge_role_output}"
  fi

else
  echo "SKIP: No edge pool; no IAM role configured for edge nodes."
fi

echo "-------------------------------------------------------------"
if [[ ${ret} -eq 0 ]]; then
  echo "RESULT: PASS - all IAM role checks succeeded"
else
  echo "RESULT: FAIL - ${ret} IAM role check(s) failed"
fi
echo "-------------------------------------------------------------"

exit $ret
