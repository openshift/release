#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat > "${SHARED_DIR}/manifest_mc-master-disable-algif-aead.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-disable-algif-aead
spec:
  kernelArguments:
    - initcall_blacklist=algif_aead_init
EOF

cat > "${SHARED_DIR}/manifest_mc-worker-disable-algif-aead.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-disable-algif-aead
spec:
  kernelArguments:
    - initcall_blacklist=algif_aead_init
EOF
