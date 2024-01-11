#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create node MachineConfig files and set kernelType to realtime
cat > "${SHARED_DIR}"/manifest_99-worker-kerneltype.yaml <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: "worker"
  name: realtime-worker
spec:
  kernelType: realtime
EOF
