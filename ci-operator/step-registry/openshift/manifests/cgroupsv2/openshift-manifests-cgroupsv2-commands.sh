#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_mc-master-cgroupsv2.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-cgroupsv2
spec:
  kernelArguments:
    - 'systemd.unified_cgroup_hierarchy=1'
EOF

cat >> "${SHARED_DIR}/manifest_mc-worker-cgroupsv2.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-cgroupsv2
spec:
  kernelArguments:
    - 'systemd.unified_cgroup_hierarchy=1'
EOF
