#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51169"

# Create node MachineConfig files and set kernelType to realtime
cat > "${SHARED_DIR}"/manifest_99-master-kerneltype.yaml <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: "master"
  name: 99-master-kerneltype
spec:
  kernelType: realtime
EOF

cat > "${SHARED_DIR}"/manifest_99-worker-kerneltype.yaml <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: "worker"
  name: 99-worker-kerneltype
spec:
  kernelType: realtime
EOF

# Restore
