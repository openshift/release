#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

sleep 4h

# Temp debug
trap 'sleep 4h' EXIT TERM SIGINT INT

ODF_INSTALL_NAMESPACE="openshift-storage"
ODF_OPERATOR_GROUP="openshift-storage-operator-group"

echo "Creating the ODF installation namespace"
oc apply -f - <<EOF
  apiVersion: v1
  kind: Namespace
  metadata:
      labels:
        openshift.io/cluster-monitoring: "true"
      name: "${ODF_INSTALL_NAMESPACE}"
EOF

echo "Selecting worker nodes for ODF"
oc label nodes cluster.ocs.openshift.io/openshift-storage='' --selector='node-role.kubernetes.io/worker' --overwrite

#echo "Applying StorageSystem after operator installation completed"
#
#cat <<EOF | oc apply -f -
#  apiVersion: odf.openshift.io/v1alpha1
#  kind: StorageSystem
#  metadata:
#    name: ocs-storagecluster-storagesystem
#    namespace: "${ODF_INSTALL_NAMESPACE}"
#  spec:
#    kind: storagecluster.ocs.openshift.io/v1
#    name: ocs-storagecluster
#    namespace: "${ODF_INSTALL_NAMESPACE}"
#EOF
#
#sleep 120

echo "INSTALL OPERATOR REF SIMULATE"

echo "Deploying a StorageCluster"
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  resources: {}
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "${ODF_STORAGE_CLAIM}"
        storageClassName: "${ODF_STORAGE_CLASS}"
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

# Need to allow some time before checking if the StorageCluster is deployed
sleep 60

echo "⏳ Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='180m'

echo "ODF Operator is deployed successfully"