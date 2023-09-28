#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

INFRA_OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F "." '{print $1"."$2}')
DEFAULT_ODF_OPERATOR_CHANNEL=""
case $INFRA_OCP_VERSION in
"4.14")
  # pre-release ocp 4.14 only has access to stable odf 4.13
  DEFAULT_ODF_OPERATOR_CHANNEL="stable-4.13"
  ;;
"4.13")
  DEFAULT_ODF_OPERATOR_CHANNEL="stable-4.13"
  ;;
"4.12")
  DEFAULT_ODF_OPERATOR_CHANNEL="stable-4.12"
  ;;
*)
  # update this catch all wildcard to stable-4.14 once the odf 4.14 is released
  DEFAULT_ODF_OPERATOR_CHANNEL="stable-4.13"
  ;;
esac

ODF_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-${DEFAULT_ODF_OPERATOR_CHANNEL}}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-'odf-operator'}"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-'gp3-csi'}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-100}Gi"
ODF_SUBSCRIPTION_SOURCE="${ODF_SUBSCRIPTION_SOURCE:-'redhat-operators'}"

# Make the masters schedulable so we have more capacity to run VMs
oc patch scheduler cluster --type=json -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'

echo "Installing ODF from ${ODF_OPERATOR_CHANNEL} into ${ODF_INSTALL_NAMESPACE}"
# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: BackingStore.v1alpha1.noobaa.io,BucketClass.v1alpha1.noobaa.io,CSIAddonsNode.v1alpha1.csiaddons.openshift.io,CephBlockPool.v1.ceph.rook.io,CephBlockPoolRadosNamespace.v1.ceph.rook.io,CephBucketNotification.v1.ceph.rook.io,CephBucketTopic.v1.ceph.rook.io,CephClient.v1.ceph.rook.io,CephCluster.v1.ceph.rook.io,CephFilesystem.v1.ceph.rook.io,CephFilesystemMirror.v1.ceph.rook.io,CephFilesystemSubVolumeGroup.v1.ceph.rook.io,CephNFS.v1.ceph.rook.io,CephObjectRealm.v1.ceph.rook.io,CephObjectStore.v1.ceph.rook.io,CephObjectStoreUser.v1.ceph.rook.io,CephObjectZone.v1.ceph.rook.io,CephObjectZoneGroup.v1.ceph.rook.io,CephRBDMirror.v1.ceph.rook.io,NamespaceStore.v1alpha1.noobaa.io,NetworkFence.v1alpha1.csiaddons.openshift.io,NooBaa.v1alpha1.noobaa.io,NooBaaAccount.v1alpha1.noobaa.io,OCSInitialization.v1.ocs.openshift.io,ObjectBucket.v1alpha1.objectbucket.io,ObjectBucketClaim.v1alpha1.objectbucket.io,ReclaimSpaceCronJob.v1alpha1.csiaddons.openshift.io,ReclaimSpaceJob.v1alpha1.csiaddons.openshift.io,StorageClassClaim.v1alpha1.ocs.openshift.io,StorageCluster.v1.ocs.openshift.io,StorageConsumer.v1alpha1.ocs.openshift.io,StorageSystem.v1alpha1.odf.openshift.io,VolumeReplication.v1alpha1.replication.storage.openshift.io,VolumeReplicationClass.v1alpha1.replication.storage.openshift.io
  name: "${ODF_INSTALL_NAMESPACE}-operator-group"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${ODF_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

echo "subscribe to the operator subscription name: $ODF_SUBSCRIPTION_NAME, namespace: $ODF_INSTALL_NAMESPACE, channel $ODF_OPERATOR_CHANNEL"
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $ODF_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: $ODF_SUBSCRIPTION_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

RETRIES=60
echo "Waiting for CSV to be available from operator group"
for ((i=1; i <= $RETRIES; i++)); do
    CSV=$(oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
	else
	   oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o yaml --ignore-not-found
        fi
    else
      echo "Try ${i}/${RETRIES}: ODF is not deployed yet. Checking again in 10 seconds"
      oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o yaml --ignore-not-found
    fi
    sleep 10
done

echo "Waiting for noobaa-operator"
for ((i=1; i <= $RETRIES; i++)); do
    NOOBAA=$(oc -n "$ODF_INSTALL_NAMESPACE" get deployment noobaa-operator --ignore-not-found)
    if [[ -n "$NOOBAA" ]]; then
       echo "Found noobaa operator"
       break
    fi
    sleep 10
done

oc wait deployment noobaa-operator \
--namespace="${ODF_INSTALL_NAMESPACE}" \
--for=condition='Available' \
--timeout='5m'

echo "Preparing nodes"
oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker' --overwrite

echo "Create StorageCluster"
cat <<EOF | oc apply -f -
kind: StorageCluster
apiVersion: ocs.openshift.io/v1
metadata:
 name: ocs-storagecluster
 namespace: $ODF_INSTALL_NAMESPACE
spec:
  resources:
    mon:
      requests:
        cpu: "0"
        memory: "0"
    mgr:
      requests:
        cpu: "0"
        memory: "0"
  monDataDirHostPath: /var/lib/rook
  managedResources:
    cephFilesystems:
      reconcileStrategy: ignore
    cephObjectStores:
      reconcileStrategy: ignore
  multiCloudGateway:
    reconcileStrategy: ignore
  storageDeviceSets:
    - name: ocs-deviceset
      count: 3
      dataPVCTemplate:
        spec:
          storageClassName: $ODF_BACKEND_STORAGE_CLASS
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: $ODF_VOLUME_SIZE
          volumeMode: Block
      placement: {}
      portable: false
      replica: 1
      resources:
        requests:
          cpu: "0"
          memory: "0"
EOF

echo "Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
   -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='10m'

echo "ODF/OCS Operator is deployed successfully"

# Setting ocs-storagecluster-ceph-rbd the default storage class
for item in $(oc get sc --no-headers | awk '{print $1}'); do
	oc annotate --overwrite sc $item storageclass.kubernetes.io/is-default-class='false'
done
oc annotate --overwrite sc ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class='true'
echo "ocs-storagecluster-ceph-rbd is set as default storage class"
