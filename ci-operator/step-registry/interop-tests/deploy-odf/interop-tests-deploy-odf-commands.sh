#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ODF_INSTALL_NAMESPACE=openshift-storage
DEFAULT_ODF_OPERATOR_CHANNEL="stable-${ODF_VERSION_MAJOR_MINOR}"
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-${DEFAULT_ODF_OPERATOR_CHANNEL}}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-'odf-operator'}"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-'gp2-csi'}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-50}Gi"

function monitor_progress() {
  local status=''
  while true; do
    echo "Checking progress..."
    oc get storagecluster.ocs.openshift.io/ocs-storagecluster -n "${ODF_INSTALL_NAMESPACE}" \
      -o jsonpath='{range .status.conditions[*]}{@}{"\n"}{end}'
    status=$(oc get "storagecluster.ocs.openshift.io/ocs-storagecluster" -n openshift-storage -o jsonpath="{.status.phase}")
    if [[ "$status" == "Ready" ]]; then
      echo "StorageCluster is Ready"
      exit 0
    fi
    sleep 30
  done
}

function run_must_gather_and_abort_on_fail() {
  local odf_must_gather_image="quay.io/rhceph-dev/ocs-must-gather:latest-${ODF_VERSION_MAJOR_MINOR}"
  # Wait for StorageCluster to be deployed, and on fail run must gather
  oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='30m' || \
  oc adm must-gather --image="${odf_must_gather_image}" --dest-dir="${ARTIFACT_DIR}/ocs_must_gather"
  # exit 1
}

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
  name: "${ODF_INSTALL_NAMESPACE}-operator-group"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${ODF_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
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
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
    CSV=$(oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    sleep 10
done

echo "Wait for OCS Operator deployment to be ready"
sleep 30

oc wait deployment ocs-operator \
  --namespace="${ODF_INSTALL_NAMESPACE}" \
  --for=condition='Available' \
  --timeout='5m'

# Preparing Nodes
oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker'

# Create StorageCluster
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: ${ODF_VOLUME_SIZE}
        storageClassName: ${ODF_BACKEND_STORAGE_CLASS}
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

# Wait 30 sec and start monitoring the progress of the StorageCluster
sleep 30
monitor_progress &
run_must_gather_and_abort_on_fail &

# Wait for StorageCluster to be deployed
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='180m'

# Remove is-default-class annotation from all the storage classes
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

# Make ocs-storagecluster-ceph-rbd the default storage class
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true


echo "ODF/OCS Operator is deployed successfully"
