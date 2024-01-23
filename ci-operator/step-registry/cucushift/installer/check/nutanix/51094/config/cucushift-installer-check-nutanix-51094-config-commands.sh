#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51094"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Set specified master and worker configurations
sed -i '/compute:/,/replicas: 3/d' "${CONFIG}"
sed -i '/controlPlane:/,/replicas: 3/d' "${CONFIG}"

cat >> "${CONFIG}" << EOF
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    nutanix:
      cpus: 4
      coresPerSocket: 2
      memoryMiB: 20000
      osDisk:
        diskSizeGiB: 100
  replicas: 2
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    nutanix:
      cpus: 4
      coresPerSocket: 2
      memoryMiB: 20000
      osDisk:
        diskSizeGiB: 100
  replicas: 3
EOF

cat "${CONFIG}"

# Restore
