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

function wait_for_mcp_to_update() {
  local mcp_name="$1"
  local mcp_timeout="$2"

  echo "Waiting for MachineConfigPool '${mcp_name}' to start updating..."
  if ! oc wait mcp "${mcp_name}" --for='condition=UPDATING=True' --timeout=300s 2>/dev/null; then
    echo "WARNING: MachineConfigPool '${mcp_name}' did not enter UPDATING state. It may already be up to date."
  fi

  echo "Waiting for MachineConfigPool '${mcp_name}' to finish updating..."
  oc wait mcp "${mcp_name}" --for='condition=UPDATED=True' --for='condition=UPDATING=False' --for='condition=DEGRADED=False' --timeout="${mcp_timeout}"

  echo "MachineConfigPool '${mcp_name}' successfully updated"
}

# Main execution
if [[ -z "${MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME}" ]]; then
  echo "MCO_CONF_DAY2_OS_IMAGE_STREAM_NAME is empty. No MachineConfigPools will be configured."
  exit 0
fi

set_proxy

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
