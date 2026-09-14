#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

# check profile tag
function has_shared_tags() {
  local txt="$1"
  if grep -qiE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*shared" "$txt"; then
    return 0
  fi
  return 1
}

# has_owned_tags reports whether the resource carries the installer ownership tag
# kubernetes.io/cluster/${INFRA_ID}: owned, which the installer attaches to the
# IAM resources it creates itself (as opposed to BYO ones, which get "shared").
function has_owned_tags() {
  local txt="$1"
  if grep -qiE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*owned" "$txt"; then
    return 0
  fi
  return 1
}

# verify_installer_default_profile checks that a pool with no BYO instance profile
# falls back to the installer-generated default: the profile must exist under the
# expected installer name, be the one actually attached to the pool's nodes, and
# carry the installer ownership tag rather than the BYO "shared" tag.
# args: <pool label> <profile attached to nodes> <expected installer default profile> <get-instance-profile output file>
function verify_installer_default_profile() {
  local label="$1" actual_profile="$2" default_profile="$3" profile_output="$4"
  local probe_output
  probe_output=$(mktemp)

  # Confirm the instance profile exists via the API using the command's exit
  # status rather than matching an error message string. On failure, the stable
  # NoSuchEntity error code distinguishes genuine absence from other query errors.
  if aws --region $REGION iam get-instance-profile --instance-profile-name ${default_profile} > ${probe_output} 2>&1; then
    echo "PASS: ${label}: installer default instance profile ${default_profile} exists."
  elif grep -q "NoSuchEntity" ${probe_output}; then
    echo "FAIL: ${label}: installer default instance profile ${default_profile} does not exist."
    ret=$((ret+1))
  else
    echo "FAIL: ${label}: error querying installer default instance profile ${default_profile}:"
    cat ${probe_output}
    ret=$((ret+1))
  fi
  rm -f ${probe_output}

  if [[ "${actual_profile}" != "${default_profile}" ]]; then
    echo "FAIL: ${label}: IAM profile mismatch: current: ${actual_profile}, expected installer default: ${default_profile}"
    ret=$((ret+1))
  else
    echo "PASS: ${label}: using installer default IAM profile ${actual_profile}"
  fi

  # get-instance-profile output includes the enclosed role's tags. Installer-owned
  # resources carry kubernetes.io/cluster/<infra>: owned; a BYO profile would
  # instead carry the shared tag.
  if has_owned_tags "${profile_output}"; then
    echo "PASS: ${label}: tag check: ${actual_profile} is installer-owned"
  else
    echo "FAIL: ${label}: tag check: ${actual_profile} is missing kubernetes.io/cluster/${INFRA_ID}: owned"
    ret=$((ret+1))
  fi

  if has_shared_tags "${profile_output}"; then
    echo "FAIL: ${label}: IAM profile ${actual_profile} carries the BYO 'shared' tag; expected installer default."
    ret=$((ret+1))
  fi
}

ret=0
output=$(mktemp)

echo "-------------------------------------------------------------"
echo "Profiles used by cluster"
echo "-------------------------------------------------------------"

control_plane_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')
compute_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')

control_plane_profile_output=$(mktemp)
compute_profile_output=$(mktemp)

aws --region $REGION iam get-instance-profile --instance-profile-name ${control_plane_profile} --output text >$control_plane_profile_output
aws --region $REGION iam get-instance-profile --instance-profile-name ${compute_profile} --output text >$compute_profile_output

echo "Control plane: profile: ${control_plane_profile}"
echo "Compute:       profile: ${compute_profile}"

# Edge compute pool nodes (AWS Local/Wavelength zones) carry the
# node-role.kubernetes.io/edge label. Discover them by label rather than by an
# assumed instance Name tag.
edge_instance_ids=$(oc get nodes -l node-role.kubernetes.io/edge -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ 'NF{print $NF}')
edge_profile=""
edge_profile_output=$(mktemp)
if [[ -n "${edge_instance_ids}" ]]; then
  edge_profile=$(aws --region $REGION ec2 describe-instances --instance-ids ${edge_instance_ids} | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $NF}')
  aws --region $REGION iam get-instance-profile --instance-profile-name ${edge_profile} --output text >$edge_profile_output
  echo "Edge:          profile: ${edge_profile}"
fi

echo "-------------------------------------------------------------"
echo "Profiles configured in install-config.yaml"
echo "-------------------------------------------------------------"

ic_platform_profile=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamProfile')
ic_control_plane_profile=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamProfile')
ic_compute_profile=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamProfile')
# The edge pool is a named compute entry (compute[name=edge]); select it by name.
ic_edge_profile=$(yq-v4 '.compute[] | select(.name == "edge").platform.aws.iamProfile' "${CONFIG}")
# Detect whether an edge pool exists at all, so defaultMachinePlatform is only
# treated as an edge expectation when there is an edge pool to apply it to.
ic_edge_pool=$(yq-v4 '.compute[] | select(.name == "edge").name' "${CONFIG}")

echo "Install config: platform: ${ic_platform_profile}, control plane: ${ic_control_plane_profile}, compute: ${ic_compute_profile}, edge: ${ic_edge_profile}"

echo "-------------------------------------------------------------"
echo "Expected profiles"
echo "-------------------------------------------------------------"

expected_control_plane_profile=""
expected_compute_profile=""
expected_edge_profile=""

# defaultMachinePlatform applies to every pool, including edge, unless overridden.
# It only implies an edge expectation when an edge pool actually exists.
if ! is_empty "$ic_platform_profile"; then
  echo "platform.aws.defaultMachinePlatform.iamProfile was found: ${ic_platform_profile}"
  expected_control_plane_profile="${ic_platform_profile}"
  expected_compute_profile="${ic_platform_profile}"
  if ! is_empty "$ic_edge_pool"; then
    expected_edge_profile="${ic_platform_profile}"
  fi
fi

if ! is_empty "$ic_control_plane_profile"; then
  echo "controlPlane.platform.aws.iamProfile was found: ${ic_control_plane_profile}"
  expected_control_plane_profile="${ic_control_plane_profile}"
fi

if ! is_empty "$ic_compute_profile"; then
  echo "compute[0].platform.aws.iamProfile was found: ${ic_compute_profile}"
  expected_compute_profile="${ic_compute_profile}"
fi

if ! is_empty "$ic_edge_profile"; then
  echo "compute[name=edge].platform.aws.iamProfile was found: ${ic_edge_profile}"
  expected_edge_profile="${ic_edge_profile}"
fi

echo "expected_control_plane_profile: $expected_control_plane_profile"
echo "expected_compute_profile: $expected_compute_profile"
echo "expected_edge_profile: $expected_edge_profile"

echo "-------------------------------------------------------------"
echo "Checking profile: control plane"
echo "-------------------------------------------------------------"

if [[ ${expected_control_plane_profile} != "" ]]; then

  # A BYO instance profile is configured, so the installer must not create its
  # default profile. Inspect the lookup exit status: success means the default
  # profile exists (unexpected), NoSuchEntity means it is absent (expected), and
  # any other failure is a query error that cannot be classified.
  profile_name=${INFRA_ID}-master-profile
  if aws --region $REGION iam get-instance-profile --instance-profile-name ${profile_name} > ${output} 2>&1; then
    echo "FAIL: ${profile_name} was found; expected only the BYO instance profile."
    ret=$((ret+1))
  elif grep -q "NoSuchEntity" ${output}; then
    echo "PASS: ${profile_name} does not exist."
  else
    echo "FAIL: error querying ${profile_name}:"
    cat ${output}
    ret=$((ret+1))
  fi

  if [[ "${control_plane_profile}" != "${expected_control_plane_profile}" ]]; then
    echo "FAIL: Control plane IAM profile mismatch: current: ${control_plane_profile}, expect: ${expected_control_plane_profile}"
    ret=$((ret+1))
  else
    echo "PASS: Control plane IAM profile"
  fi

  if ! has_shared_tags ${control_plane_profile_output}; then
    echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${control_plane_profile}"
    ret=$((ret + 1))
  else
    echo "PASS: tag check: ${control_plane_profile}"
  fi

else
  # No BYO profile configured; verify the control plane uses the installer default.
  verify_installer_default_profile "control plane" "${control_plane_profile}" "${INFRA_ID}-master-profile" "${control_plane_profile_output}"
fi

echo "-------------------------------------------------------------"
echo "Checking profile: compute"
echo "-------------------------------------------------------------"

if [[ ${expected_compute_profile} != "" ]]; then

  profile_name=${INFRA_ID}-worker-profile
  if aws --region $REGION iam get-instance-profile --instance-profile-name ${profile_name} > ${output} 2>&1; then
    echo "FAIL: ${profile_name} was found; expected only the BYO instance profile."
    ret=$((ret+1))
  elif grep -q "NoSuchEntity" ${output}; then
    echo "PASS: ${profile_name} does not exist."
  else
    echo "FAIL: error querying ${profile_name}:"
    cat ${output}
    ret=$((ret+1))
  fi

  if [[ "${compute_profile}" != "${expected_compute_profile}" ]]; then
    echo "FAIL: Compute IAM profile mismatch: current: ${compute_profile}, expect: ${expected_compute_profile}"
    ret=$((ret + 1))
  else
    echo "PASS: Compute IAM profile"
  fi

  if ! has_shared_tags ${compute_profile_output}; then
    echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${compute_profile}"
    ret=$((ret + 1))
  else
    echo "PASS: tag check: ${compute_profile}"
  fi
else
  # No BYO profile configured; verify the compute pool uses the installer default.
  verify_installer_default_profile "compute" "${compute_profile}" "${INFRA_ID}-worker-profile" "${compute_profile_output}"
fi

echo "-------------------------------------------------------------"
echo "Checking profile: edge"
echo "-------------------------------------------------------------"

if [[ ${expected_edge_profile} != "" ]]; then

  if [[ -z "${edge_instance_ids}" ]]; then
    echo "FAIL: expected edge IAM profile ${expected_edge_profile} but no edge nodes (node-role.kubernetes.io/edge) were found."
    ret=$((ret+1))
  else
    if [[ "${edge_profile}" != "${expected_edge_profile}" ]]; then
      echo "FAIL: Edge IAM profile mismatch: current: ${edge_profile}, expect: ${expected_edge_profile}"
      ret=$((ret + 1))
    else
      echo "PASS: Edge IAM profile"
    fi

    if ! has_shared_tags ${edge_profile_output}; then
      echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${edge_profile}"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${edge_profile}"
    fi
  fi

elif ! is_empty "$ic_edge_pool"; then

  # An edge pool exists but no BYO IAM profile was configured for it, so the edge
  # nodes must fall back to the installer-generated default instance profile. The
  # edge pool gets its own profile named ${INFRA_ID}-edge-profile (see
  # openshift/installer#10836).
  if [[ -z "${edge_instance_ids}" ]]; then
    echo "FAIL: edge pool is configured but no edge nodes (node-role.kubernetes.io/edge) were found."
    ret=$((ret+1))
  else
    verify_installer_default_profile "edge" "${edge_profile}" "${INFRA_ID}-edge-profile" "${edge_profile_output}"
  fi

else
  echo "SKIP: No edge pool; no IAM profile configured for edge nodes."
fi

echo "-------------------------------------------------------------"
if [[ ${ret} -eq 0 ]]; then
  echo "RESULT: PASS - all IAM profile checks succeeded"
else
  echo "RESULT: FAIL - ${ret} IAM profile check(s) failed"
fi
echo "-------------------------------------------------------------"

exit $ret
