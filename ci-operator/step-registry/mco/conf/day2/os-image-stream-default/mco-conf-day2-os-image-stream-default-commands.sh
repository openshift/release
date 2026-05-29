#!/bin/bash

set -e
set -u
set -o pipefail

function set_proxy () {
    if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
        echo "Setting the proxy ${SHARED_DIR}/proxy-conf.sh"
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings"
    fi
}

function get_default_stream() {
  echo "Retrieving default stream from OSImageStream resource..." >&2

  local default_stream
  default_stream=$(oc get osimagestream cluster -o jsonpath='{.status.defaultStream}')

  if [[ -z "${default_stream}" ]]; then
    echo "WARNING: Could not find default stream in OSImageStream resource" >&2
    return 1
  fi

  echo "Default stream: ${default_stream}" >&2
  echo "${default_stream}"
}

function get_osimage_for_stream() {
  local stream_name="$1"

  echo "Retrieving osImage for stream '${stream_name}' from OSImageStream resource..."

  local osimage
  osimage=$(oc get osimagestream cluster -o jsonpath="{.status.availableStreams[?(@.name=='${stream_name}')].osImage}")

  if [[ -z "${osimage}" ]]; then
    echo "ERROR: Could not find osImage for stream '${stream_name}' in OSImageStream resource"
    return 1
  fi

  echo "Found osImage for stream '${stream_name}': ${osimage}"
  echo "${osimage}"
}

function set_default_stream() {
  local stream_name="$1"

  echo "Setting default osImageStream to '${stream_name}' in the OSImageStream cluster resource"

  local patch_output
  patch_output=$(oc patch osimagestream cluster --type merge -p "{\"spec\":{\"defaultStream\":\"${stream_name}\"}}" 2>&1)
  local patch_exit_code=$?

  echo "${patch_output}"

  if [[ ${patch_exit_code} -ne 0 ]]; then
    echo "ERROR: Failed to patch OSImageStream cluster resource"
    return 1
  fi

  if echo "${patch_output}" | grep -qi "unknown field"; then
    echo "ERROR: The 'defaultStream' field is not recognized by the OSImageStream API"
    echo "This likely means the OSStreams feature is not available or the feature gate is not enabled"
    return 1
  fi

  echo "Successfully set default osImageStream to '${stream_name}'"
}

function get_mcp_current_stream() {
  local mcp_name="$1"

  # Check if the MCP has a per-pool osImageStream override
  local mcp_stream
  mcp_stream=$(oc get mcp "${mcp_name}" -o jsonpath='{.spec.osImageStream.name}' 2>/dev/null)

  if [[ -n "${mcp_stream}" ]]; then
    echo "${mcp_stream}"
    return 0
  fi

  # No per-pool override, the MCP uses the cluster default
  local default_stream
  default_stream=$(oc get osimagestream cluster -o jsonpath='{.status.defaultStream}' 2>/dev/null)
  echo "${default_stream}"
}

function wait_for_mcps_updating() {
  local mcp_timeout="$1"
  shift
  local mcp_names=("$@")

  echo "Waiting for ${#mcp_names[@]} MachineConfigPool(s) to start updating..."
  for mcp_name in "${mcp_names[@]}"; do
    echo "Waiting for MachineConfigPool '${mcp_name}' to start updating..."
    if ! oc wait mcp "${mcp_name}" --for='condition=UPDATING=True' --timeout=300s 2>/dev/null; then
      echo "WARNING: MachineConfigPool '${mcp_name}' did not enter UPDATING state. It may already be up to date."
    fi
  done

  echo "All MachineConfigPools have started updating. Waiting for them to finish..."
  for mcp_name in "${mcp_names[@]}"; do
    echo "Waiting for MachineConfigPool '${mcp_name}' to finish updating..."
    until oc wait mcp "${mcp_name}" --for='condition=UPDATING=False' --timeout="${mcp_timeout}" 2>/dev/null; do
      echo "API server unavailable, retrying in 30s..."
      sleep 30
    done
    echo "MachineConfigPool '${mcp_name}' successfully updated"
  done
}

function verify_node_osimage() {
  local node_name="$1"
  local expected_osimage="$2"

  echo "Verifying osImage on node '${node_name}'..."

  local rpm_ostree_output
  if ! rpm_ostree_output=$(oc debug -n default node/"${node_name}" -- chroot /host rpm-ostree status 2>&1); then
    echo "ERROR: Failed to run rpm-ostree status on node '${node_name}'"
    echo "${rpm_ostree_output}"
    return 1
  fi

  echo "rpm-ostree status output for node '${node_name}':"
  echo "${rpm_ostree_output}"

  local expected_digest
  expected_digest=$(echo "${expected_osimage}" | grep -oP 'sha256:[a-f0-9]+')

  if [[ -z "${expected_digest}" ]]; then
    echo "ERROR: Could not extract digest from expected osImage: ${expected_osimage}"
    return 1
  fi

  echo "Expected digest: ${expected_digest}"

  if echo "${rpm_ostree_output}" | grep -q "${expected_digest}"; then
    echo "SUCCESS: Node '${node_name}' is using the expected osImage with digest ${expected_digest}"
    return 0
  else
    echo "ERROR: Node '${node_name}' is NOT using the expected osImage"
    echo "Expected digest: ${expected_digest}"
    echo "rpm-ostree status did not contain the expected digest"
    return 1
  fi
}

function verify_mcp_nodes_osimage() {
  local mcp_name="$1"
  local expected_osimage="$2"

  echo "Verifying that all nodes in MachineConfigPool '${mcp_name}' are using osImage: ${expected_osimage}"

  local nodes
  nodes=$(oc get nodes -l "node-role.kubernetes.io/${mcp_name}" -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "${nodes}" ]]; then
    echo "WARNING: No nodes found for MachineConfigPool '${mcp_name}'"
    return 0
  fi

  local node_array
  read -ra node_array <<< "${nodes}"

  echo "Found ${#node_array[@]} node(s) in MachineConfigPool '${mcp_name}': ${node_array[*]}"

  local verification_failed=0

  for node in "${node_array[@]}"; do
    if ! verify_node_osimage "${node}" "${expected_osimage}"; then
      verification_failed=1
    fi
  done

  if [[ ${verification_failed} -eq 1 ]]; then
    echo "ERROR: One or more nodes in MachineConfigPool '${mcp_name}' failed osImage verification"
    return 1
  fi

  echo "All nodes in MachineConfigPool '${mcp_name}' successfully verified"
  return 0
}

# Main execution
if [[ -z "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}" ]]; then
  echo "MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT is empty. Skipping."
  exit 0
fi

set_proxy

# Print the OSImageStream resource for debugging
echo "=========================================="
echo "OSImageStream cluster resource:"
echo "=========================================="
oc get osimagestream cluster -o yaml
echo ""

# Check if the selected stream is already the default
if default_stream=$(get_default_stream); then
  if [[ "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}" == "${default_stream}" ]]; then
    echo "The selected stream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}' is already the default stream. No configuration needed."
    exit 0
  fi
else
  echo "WARNING: Could not retrieve default stream. Proceeding with configuration anyway."
fi

# Get the expected osImage for verification
expected_osimage=$(get_osimage_for_stream "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}")
if [[ -z "${expected_osimage}" ]]; then
  echo "ERROR: Failed to retrieve osImage for stream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}'"
  exit 1
fi

# Collect all MCPs and determine which ones need updating
mapfile -t mcp_list < <(oc get mcp -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
if [[ ${#mcp_list[@]} -eq 0 ]]; then
  echo "ERROR: No MachineConfigPools found in the cluster"
  exit 1
fi

# Record the effective stream for each MCP before changing the default,
# so we know which ones will actually change.
# MCPs with a per-pool osImageStream override are unaffected by the cluster default.
declare -a mcps_to_update=()
declare -a mcps_to_verify=()
for mcp_name in "${mcp_list[@]}"; do
  mcp_override=$(oc get mcp "${mcp_name}" -o jsonpath='{.spec.osImageStream.name}' 2>/dev/null)
  if [[ -n "${mcp_override}" ]]; then
    echo "MCP '${mcp_name}' has a per-pool osImageStream override '${mcp_override}', skipping (not affected by default stream change)"
    continue
  fi
  mcps_to_verify+=("${mcp_name}")
  current_stream=$(get_mcp_current_stream "${mcp_name}")
  if [[ "${current_stream}" != "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}" ]]; then
    echo "MCP '${mcp_name}' currently uses stream '${current_stream}', will change to '${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}'"
    mcps_to_update+=("${mcp_name}")
  else
    echo "MCP '${mcp_name}' already uses stream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}', skipping wait"
  fi
done

# Set the default stream
set_default_stream "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT}"

# Only wait for MCPs whose stream actually changed
if [[ ${#mcps_to_update[@]} -gt 0 ]]; then
  wait_for_mcps_updating "${MCO_CONF_DAY2_OS_IMAGE_STREAM_DEFAULT_TIMEOUT}" "${mcps_to_update[@]}"
else
  echo "No MachineConfigPools need updating"
fi

echo "All MachineConfigPools configured successfully"
echo "Current MachineConfigPool status:"
oc get mcp

echo ""
echo "=========================================="
echo "Verifying osImage on nodes..."
echo "=========================================="

verification_failed=0
for mcp_name in "${mcps_to_verify[@]}"; do
  if ! verify_mcp_nodes_osimage "${mcp_name}" "${expected_osimage}"; then
    verification_failed=1
  fi
done

if [[ ${verification_failed} -eq 1 ]]; then
  echo ""
  echo "ERROR: osImage verification failed for one or more MachineConfigPools"
  exit 1
fi

echo ""
echo "=========================================="
echo "SUCCESS: All nodes verified successfully"
echo "=========================================="
