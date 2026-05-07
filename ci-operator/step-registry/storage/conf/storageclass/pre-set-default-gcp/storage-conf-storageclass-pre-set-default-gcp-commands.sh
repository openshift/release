#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat << EOF > ${SHARED_DIR}/manifest_storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${GCP_SC_DISK_TYPE}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: ${GCP_SC_DISK_TYPE}
  replication-type: none
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

cat << EOF > ${SHARED_DIR}/manifest_cluster_csi_driver.yaml
apiVersion: operator.openshift.io/v1
kind: "ClusterCSIDriver"
metadata:
  name: "pd.csi.storage.gke.io"
spec:
  logLevel: Normal
  managementState: Managed
  operatorLogLevel: Normal
  storageClassState: Unmanaged
EOF
