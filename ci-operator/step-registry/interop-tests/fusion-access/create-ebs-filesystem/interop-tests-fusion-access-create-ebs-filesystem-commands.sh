#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

echo "🗂️  Creating IBM Storage Scale Filesystem..."

# Create Filesystem resource referencing LocalDisk resources
oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shared-ebs-disk-1
      - shared-ebs-disk-2
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF

echo "✅ Filesystem resource created"
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE}

echo ""
echo "Note: Filesystem initialization may take up to 1 hour"
echo "Check filesystem status with: oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE}"
