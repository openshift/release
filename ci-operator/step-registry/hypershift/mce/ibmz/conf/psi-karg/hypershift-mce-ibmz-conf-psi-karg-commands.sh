#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Creating PSI karg MachineConfig install manifests..."

cat >> "${SHARED_DIR}/manifest_psi-karg-master-mc.yml" << 'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-openshift-machineconfig-master-psi-karg
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  kernelArguments:
    - psi=1
EOF

cat >> "${SHARED_DIR}/manifest_psi-karg-worker-mc.yml" << 'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-openshift-machineconfig-worker-psi-karg
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - psi=1
EOF

echo "PSI karg MachineConfig manifests created for master and worker nodes"
