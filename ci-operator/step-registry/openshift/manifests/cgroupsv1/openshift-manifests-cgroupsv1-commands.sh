#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_mc-master-cgroupsv1.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-cgroupsv1
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=0
    - systemd.legacy_systemd_cgroup_controller=1
EOF

cat >> "${SHARED_DIR}/manifest_mc-worker-cgroupsv1.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-cgroupsv1
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=0
    - systemd.legacy_systemd_cgroup_controller=1
EOF
