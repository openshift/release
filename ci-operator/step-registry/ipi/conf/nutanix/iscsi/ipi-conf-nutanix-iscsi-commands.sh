#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${SHARED_DIR}/nutanix_context.sh


echo "$(date -u --rfc-3339=seconds) - Manifests to enable iSCSI for all nodes ..."

cat > "${SHARED_DIR}/manifest_iscsid-enable-master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-ntnx-csi-enable-iscsid
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - enabled: true
        name: iscsid.service
EOF

cat > "${SHARED_DIR}/manifest_iscsid-enable-worker.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-ntnx-csi-enable-iscsid
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - enabled: true
        name: iscsid.service
EOF
