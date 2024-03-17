#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export DEVICE="/dev/vdb"

oc apply -f - <<EOF
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  finalizers:
  - lvmcluster.topolvm.io
  name: my-lvmcluster
  namespace: openshift-lvm-storage
spec:
  storage:
    deviceClasses:
    - default: true
      deviceSelector:
        paths:
        - $DEVICE
      fstype: xfs
      name: vg1
      thinPoolConfig:
        name: thin-pool-1
        overprovisionRatio: 10
        sizePercent: 90

EOF
