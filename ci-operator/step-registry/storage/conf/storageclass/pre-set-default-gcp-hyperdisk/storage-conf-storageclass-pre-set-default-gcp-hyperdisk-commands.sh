#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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

if [ "${HYPERDISK_THROUGHPUT_STORAGECLASS:-}" = "true" ]; then
    # Not the default: registry and monitoring stay on hyperdisk-balanced.
    # Hyperdisk Throughput volumes are 2Ti minimum.
    cat << EOF > "${SHARED_DIR}/manifest_hyperdisk-throughput-storageclass.yaml"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hyperdisk-throughput
provisioner: pd.csi.storage.gke.io
parameters:
  type: hyperdisk-throughput
  provisioned-throughput-on-create: "50Mi"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
fi
