#!/usr/bin/env bash

# Configure AWS compute nodes to enable nested virtualization
#
# This step creates a patch file that ipi-conf-aws will merge.
# If called after ipi-conf-aws (in test override), it merges immediately.

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "Configuring AWS nested virtualization..."

# If install-config.yaml already exists, configure it now
if [[ -f "${CONFIG}" ]]; then
  echo "install-config.yaml exists, configuring nested virtualization..."

  # Find the worker compute pool (usually index 0)
  WORKER_INDEX=$(yq-go r "${CONFIG}" 'compute[*].name' | grep -n "^worker$" | head -1 | cut -d: -f1)
  WORKER_INDEX=$((WORKER_INDEX - 1))  # Convert to 0-based index

  if [[ "${WORKER_INDEX}" -lt 0 ]]; then
    echo "ERROR: Could not find worker compute pool in install-config.yaml"
    exit 1
  fi

  echo "Configuring worker compute pool at index ${WORKER_INDEX}"

  # Set ClusterAPI management and nested virtualization on the worker pool
  yq-go w -i "${CONFIG}" "compute[${WORKER_INDEX}].management" "ClusterAPI"
  yq-go w -i "${CONFIG}" "compute[${WORKER_INDEX}].platform.aws.cpuOptions.nestedVirtualization" "Enabled"

  # Copy modified config to artifacts
  cp "${CONFIG}" "${ARTIFACT_DIR}/install-config-nested-virt.yaml" || true

  echo "Nested virtualization configuration applied to install-config.yaml"
else
  echo "install-config.yaml doesn't exist yet - this step must run after ipi-conf-aws"
  exit 1
fi
