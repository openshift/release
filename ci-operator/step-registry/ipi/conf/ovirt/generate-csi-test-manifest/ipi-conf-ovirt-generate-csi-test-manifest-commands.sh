#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >"${SHARED_DIR}/csi-test-manifest.yaml" << EOF
# Test manifest for https://github.com/kubernetes/kubernetes/tree/master/test/e2e/storage/external
ShortName: ebs
StorageClass:
  FromExistingClassName: ovirt-csi-sc
DriverInfo:
  Name: csi.ovirt.org
  SupportedSizeRange:
    Min: 1Gi
    Max: 5Gi
  SupportedFsType:
    xfs: {}
    ext4: {}
  Capabilities:                 # Refer to https://github.com/kubernetes/kubernetes/blob/v1.16.0/test/e2e/storage/testsuites/testdriver.go#L140-L159
    persistence: true           # data is persisted across pod restarts
    block: true                 # raw block mode
    fsGroup: true               # volume ownership via fsGroup
    exec: true                  # exec a file in the volume
    snapshotDataSource: false   # support populate data from snapshot
    pvcDataSource: false        # support populate data from pvc
    multipods: false            # multiple pods on a node can use the same volume concurrently
    RWX: false                  # support ReadWriteMany access modes
    controllerExpansion: true   # support volume expansion for controller
    nodeExpansion: true         # support volume expansion for node
    volumeLimits: false         # support volume limits (can be *very* slow)
EOF