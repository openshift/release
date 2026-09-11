#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# In 4.11 we introduced `cgroupMode` in Node API. However we still need to
# support the 4.10 CI jobs that exist with cgroupsv2.

cat >> "${SHARED_DIR}/manifest_mc-master-cgroupsv2.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-cgroupsv2
spec:
  kernelArguments:
    - systemd.unified_cgroup_hierarchy=1
    - cgroup_no_v1="all"
    - psi=1
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
    - systemd.unified_cgroup_hierarchy=1
    - cgroup_no_v1="all"
    - psi=1
EOF
