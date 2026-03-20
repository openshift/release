#!/bin/bash

set -euo pipefail

if [[ -z "${OS_IMAGE_URL:-}" ]]; then
  echo "OS_IMAGE_URL is not set, skipping custom OS layer MachineConfig generation"
  exit 0
fi

echo "Generating custom OS layer MachineConfig with OS_IMAGE_URL=${OS_IMAGE_URL}"

mc_spec="  osImageURL: ${OS_IMAGE_URL}"

if [[ -n "${OS_EXTENTION_URL:-}" ]]; then
  echo "Including baseOSExtensionsContainerImage=${OS_EXTENTION_URL}"
  mc_spec="${mc_spec}
  baseOSExtensionsContainerImage: ${OS_EXTENTION_URL}"
fi

cat > "${SHARED_DIR}/manifest_custom-os-layer.machineconfig.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-custom-rhcos
spec:
${mc_spec}
EOF

echo "Wrote MachineConfig to ${SHARED_DIR}/manifest_custom-os-layer.machineconfig.yaml"
