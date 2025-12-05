#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"

echo "🗂️  Creating IBM Storage Scale Filesystem..."

# Create Filesystem resource referencing LocalDisk resources
oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shared-ebs-disk-0
      - shared-ebs-disk-1
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF

echo "✅ Filesystem resource created"
oc get filesystem shared-filesystem -n ${FA__SCALE__NAMESPACE}

echo ""
echo "Waiting for filesystem to be ready (may take up to 1 hour)..."
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  filesystem/shared-filesystem \
  -n ${FA__SCALE__NAMESPACE} \
  --timeout=3600s

echo "✅ Filesystem is ready"
