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

function set_os_image_stream() {
  local mcp_name="$1"
  local stream_name="$2"

  echo "Configuring MachineConfigPool '${mcp_name}' to use osImageStream '${stream_name}'"

  # Check if the MCP exists
  if ! oc get mcp "${mcp_name}" &>/dev/null; then
    echo "ERROR: MachineConfigPool '${mcp_name}' does not exist"
    return 1
  fi

  # Patch the MCP to set the osImageStream
  # Capture both stdout and stderr to detect unknown field warnings
  local patch_output
  patch_output=$(oc patch mcp "${mcp_name}" --type merge -p "{\"spec\":{\"osImageStream\":{\"name\":\"${stream_name}\"}}}" 2>&1)
  local patch_exit_code=$?

  # Print the original output
  echo "${patch_output}"

  # Check if patch failed
  if [[ ${patch_exit_code} -ne 0 ]]; then
    echo "ERROR: Failed to patch MachineConfigPool '${mcp_name}'"
    return 1
  fi

  # Check for unknown field warning
  if echo "${patch_output}" | grep -qi "unknown field"; then
    echo "ERROR: The 'osImageStream' field is not recognized by the cluster's MachineConfigPool API"
    echo "This likely means the OSStreams feature is not available or the feature gate is not enabled"
    return 1
  fi

  echo "Successfully configured osImageStream for MCP '${mcp_name}'"
}

function get_default_stream() {
  echo "Retrieving default stream from OSImageStream resource..." >&2

  # Get the default stream from the OSImageStream resource
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

  # Get the osImage from the OSImageStream resource
  local osimage
  osimage=$(oc get osimagestream cluster -o jsonpath="{.status.availableStreams[?(@.name=='${stream_name}')].osImage}")

  if [[ -z "${osimage}" ]]; then
    echo "ERROR: Could not find osImage for stream '${stream_name}' in OSImageStream resource"
    return 1
  fi

  echo "Found osImage for stream '${stream_name}': ${osimage}"
  echo "${osimage}"
}

function wait_for_mcp_to_update() {
  local mcp_name="$1"
  local mcp_timeout="$2"

  echo "Waiting for MachineConfigPool '${mcp_name}' to start updating..."
  if ! oc wait mcp "${mcp_name}" --for='condition=UPDATING=True' --timeout=300s 2>/dev/null; then
    echo "WARNING: MachineConfigPool '${mcp_name}' did not enter UPDATING state. It may already be up to date."
  fi

  echo "Waiting for MachineConfigPool '${mcp_name}' to finish updating..."
  oc wait mcp "${mcp_name}" --for='condition=UPDATING=False' --timeout="${mcp_timeout}"

  echo "MachineConfigPool '${mcp_name}' successfully updated"
}

function verify_node_osimage() {
  local node_name="$1"
  local expected_osimage="$2"

  echo "Verifying osImage on node '${node_name}'..."

  # Run rpm-ostree status on the node
  local rpm_ostree_output
  if ! rpm_ostree_output=$(oc debug node/"${node_name}" -- chroot /host rpm-ostree status 2>&1); then
    echo "ERROR: Failed to run rpm-ostree status on node '${node_name}'"
    echo "${rpm_ostree_output}"
    return 1
  fi

  echo "rpm-ostree status output for node '${node_name}':"
  echo "${rpm_ostree_output}"

  # Extract the image digest from the expected osImage (format: registry/path@sha256:digest)
  local expected_digest
  expected_digest=$(echo "${expected_osimage}" | grep -oP 'sha256:[a-f0-9]+')

  if [[ -z "${expected_digest}" ]]; then
    echo "ERROR: Could not extract digest from expected osImage: ${expected_osimage}"
    return 1
  fi

  echo "Expected digest: ${expected_digest}"

  # Check if the digest appears in the rpm-ostree status output
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

  # Get all nodes in this MCP
  local nodes
  nodes=$(oc get nodes -l "node-role.kubernetes.io/${mcp_name}" -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "${nodes}" ]]; then
    echo "WARNING: No nodes found for MachineConfigPool '${mcp_name}'"
    return 0
  fi

  # Convert to array
  local node_array
  read -ra node_array <<< "${nodes}"

  echo "Found ${#node_array[@]} node(s) in MachineConfigPool '${mcp_name}': ${node_array[*]}"

  local verification_failed=0

  # Verify each node
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
if [[ -z "${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}" ]]; then
  echo "MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME is empty. No MachineConfigPools will be configured."
  exit 0
fi

set_proxy

# Print the OSImageStream resource for debugging
echo "=========================================="
echo "OSImageStream cluster resource:"
echo "=========================================="
oc get osimagestream cluster -o yaml
echo ""

# Check if the selected stream is the default stream
if default_stream=$(get_default_stream); then
  if [[ "${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}" == "${default_stream}" ]]; then
    echo "The selected stream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}' is the default stream. No configuration needed."
    exit 0
  fi
else
  echo "WARNING: Could not retrieve default stream. Proceeding with configuration anyway."
fi

# Get the expected osImage for the stream
expected_osimage=$(get_osimage_for_stream "${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}")
if [[ -z "${expected_osimage}" ]]; then
  echo "ERROR: Failed to retrieve osImage for stream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}'"
  exit 1
fi

# Determine which MCPs to configure
declare -a mcp_list
if [[ -z "${MCO_CONF_DAY2_OS_IMAGE_STREAM_POOLS}" ]]; then
  echo "MCO_CONF_DAY2_OS_IMAGE_STREAM_POOLS is empty. Configuring ALL MachineConfigPools in the cluster."

  # Get all MCP names from the cluster
  mapfile -t mcp_list < <(oc get mcp -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

  if [[ ${#mcp_list[@]} -eq 0 ]]; then
    echo "ERROR: No MachineConfigPools found in the cluster"
    exit 1
  fi

  echo "Found ${#mcp_list[@]} MachineConfigPools: ${mcp_list[*]}"
else
  echo "Configuring specified MachineConfigPools: ${MCO_CONF_DAY2_OS_IMAGE_STREAM_POOLS}"
  # Convert space-separated list to array
  read -ra mcp_list <<< "${MCO_CONF_DAY2_OS_IMAGE_STREAM_POOLS}"
fi

echo "Configuring osImageStream '${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}' on ${#mcp_list[@]} MachineConfigPool(s)"

# Configure each MCP
for mcp_name in "${mcp_list[@]}"; do
  set_os_image_stream "${mcp_name}" "${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}"
done

# Wait for each MCP to be updated
for mcp_name in "${mcp_list[@]}"; do
  wait_for_mcp_to_update "${mcp_name}" "${MCO_CONF_DAY2_OS_IMAGE_STREAM_TIMEOUT}"
done

echo "All MachineConfigPools configured successfully"
echo "Current MachineConfigPool status:"
oc get mcp

echo ""
echo "=========================================="
echo "Verifying osImage on nodes..."
echo "=========================================="

# Verify each MCP's nodes are using the correct osImage
verification_failed=0
for mcp_name in "${mcp_list[@]}"; do
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
