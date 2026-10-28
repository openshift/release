#!/usr/bin/env bash

# Configure AWS compute nodes to enable nested virtualization via install-config.yaml
#
# This script creates and merges a patch file to add:
#   compute[*].platform.aws.cpuOptions.nestedVirtualization: Enabled

set -eu
set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-nested-virt.yaml.patch"

printf "Creating nested virtualization patch file...\n"

cat > "${PATCH}" << EOF
compute:
- name: worker
  management: ClusterAPI
  platform:
    aws:
      cpuOptions:
        nestedVirtualization: Enabled
EOF

printf "Merging nested virtualization configuration into install-config.yaml...\n"
yq-go m -a -x -i "${CONFIG}" "${PATCH}"

# Add the patch and final config to the artifact directory
cp "${PATCH}" "${CONFIG}" "${ARTIFACT_DIR}/" || true

printf "Nested virtualization configuration added to install-config.yaml\n"
