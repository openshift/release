#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# Patch control plane and compute disk type to hyperdisk-balanced for n4a instances
# n4a-standard-4 (ARM Axion) only supports hyperdisk-balanced, not pd-ssd
echo "Patching control plane and compute disk type to hyperdisk-balanced"

# Create a patch file
cat > "${SHARED_DIR}/install-config-disk.yaml.patch" << EOF
controlPlane:
  platform:
    gcp:
      osDisk:
        diskType: hyperdisk-balanced
compute:
- name: worker
  platform:
    gcp:
      osDisk:
        diskType: hyperdisk-balanced
EOF

# Merge the patch with the existing install-config
yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/install-config-disk.yaml.patch"

echo "Control plane and compute disk type updated to hyperdisk-balanced"