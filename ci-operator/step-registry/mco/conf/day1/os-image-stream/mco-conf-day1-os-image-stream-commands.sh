#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${MCO_CONF_DAY1_OS_IMAGE_STREAM_POOLS}" ]]; then
  echo "MCO_CONF_DAY1_OS_IMAGE_STREAM_POOLS is empty. No MachineConfigPool manifests will be created."
  exit 0
fi

if [[ -z "${MCO_CONF_DAY1_OS_IMAGE_STREAM_NAME}" ]]; then
  echo "MCO_CONF_DAY1_OS_IMAGE_STREAM_NAME is empty. No MachineConfigPool manifests will be created."
  exit 0
fi

function create_mcp_manifest() {
  local manifests_dir="${1}"
  local mcp_name="${2}"
  local stream_name="${3}"

  local manifest_file="${manifests_dir}/manifest_mcp-${mcp_name}-osimagestream.yaml"

  echo "Creating MachineConfigPool manifest for '${mcp_name}' with osImageStream '${stream_name}'"

  # Determine the appropriate machineConfigSelector and nodeSelector based on pool name
  local role="${mcp_name}"
  local node_selector_key="node-role.kubernetes.io/${role}"

  # Generate labels section based on pool type
  local labels_section=""
  if [[ "${mcp_name}" == "master" ]]; then
    labels_section="  labels:
    operator.machineconfiguration.openshift.io/required-for-upgrade: \"\"
    machineconfiguration.openshift.io/mco-built-in: \"\"
    pools.operator.machineconfiguration.openshift.io/master: \"\""
  elif [[ "${mcp_name}" == "worker" ]]; then
    labels_section="  labels:
    machineconfiguration.openshift.io/mco-built-in: \"\"
    pools.operator.machineconfiguration.openshift.io/worker: \"\""
  fi

  cat > "${manifest_file}" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: ${mcp_name}
${labels_section}
spec:
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: ${role}
  nodeSelector:
    matchLabels:
      ${node_selector_key}: ""
  osImageStream:
    name: ${stream_name}
EOF

  echo "Created manifest: ${manifest_file}"
  cat "${manifest_file}"
  echo ""
}

echo "Creating MachineConfigPool manifests with osImageStream '${MCO_CONF_DAY1_OS_IMAGE_STREAM_NAME}' for pools: ${MCO_CONF_DAY1_OS_IMAGE_STREAM_POOLS}"

# Convert space-separated list to array
read -ra mcp_list <<< "${MCO_CONF_DAY1_OS_IMAGE_STREAM_POOLS}"

# Validate that only master and worker pools are specified
for mcp_name in "${mcp_list[@]}"; do
  if [[ "${mcp_name}" != "master" && "${mcp_name}" != "worker" ]]; then
    echo "ERROR: Only 'master' and 'worker' pools are allowed for day-1 configuration."
    echo "Pool '${mcp_name}' is not valid. Custom pools should be configured using day-2 steps."
    exit 1
  fi
done

# Create manifest for each MCP
for mcp_name in "${mcp_list[@]}"; do
  create_mcp_manifest "${SHARED_DIR}" "${mcp_name}" "${MCO_CONF_DAY1_OS_IMAGE_STREAM_NAME}"
done

echo ""
echo "All MachineConfigPool manifests created successfully with osImageStream configuration"
