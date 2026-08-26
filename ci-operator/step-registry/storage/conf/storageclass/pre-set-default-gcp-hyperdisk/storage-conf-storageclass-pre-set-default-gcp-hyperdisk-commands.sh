#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${SET_DEFAULT_HYPERDISK_STORAGECLASS:-true}" != "true" ]]; then
  echo "SET_DEFAULT_HYPERDISK_STORAGECLASS is not \"true\"; skipping default hyperdisk-balanced StorageClass and GCP PD CSI driver overrides."
  exit 0
fi

cat << EOF > ${SHARED_DIR}/manifest_storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hyperdisk-balanced
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-balanced
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
