#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator
    cp test/e2e/aws-ebs/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
    if [ -f "test/e2e/aws-ebs/volumeattributesclass.yaml" ]; then
        cp test/e2e/aws-ebs/volumeattributesclass.yaml "${SHARED_DIR}/"
    fi
    cat <<EOF > "${SHARED_DIR}"/volumeattributesclass.yaml
# Copyright 2024 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

apiVersion: storage.k8s.io/v1
kind: VolumeAttributesClass
metadata:
  name: gp2-class
driverName: ebs.csi.aws.com
parameters:
  type: gp2
EOF
    cat <<EOF > "${SHARED_DIR}"/"${TEST_CSI_DRIVER_MANIFEST}"
ShortName: ebs
StorageClass:
  FromExistingClassName: gp2-csi
SnapshotClass:
  FromName: true
VolumeAttributesClass:
  FromFile: volumeattributesclass.yaml
DriverInfo:
  Name: ebs.csi.aws.com
  SupportedSizeRange:
    Min: 1Gi
    Max: 16Ti
  SupportedFsType:
    xfs: {}
    ext4: {}
  SupportedMountOption:
    dirsync: {}
  TopologyKeys: ["topology.ebs.csi.aws.com/zone"]
  Capabilities:
    persistence: true
    fsGroup: true
    block: true
    exec: true
    volumeLimits: false
    controllerExpansion: true
    nodeExpansion: true
    snapshotDataSource: true
    topology: true
    multipods: true
    multiplePVsSameID: true
EOF
    if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
        cp test/e2e/aws-ebs/ocp-manifest.yaml ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
        echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
        cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    fi
    if [ -f "test/e2e/aws-ebs/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}" ]; then
        echo "Copying ${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} to ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}"
        cp test/e2e/aws-ebs/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
        cat ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
    fi
else
    echo "Using aws-ebs-csi-driver-operator repo"
    cd /go/src/github.com/openshift/aws-ebs-csi-driver-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
