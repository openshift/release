#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ODF_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="$ODF_OPERATOR_CHANNEL"
ODF_SUBSCRIPTION_NAME="$ODF_SUBSCRIPTION_NAME"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-'gp2'}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-50}Gi"


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

oc wait deployment ocs-operator \
  --namespace="${ODF_INSTALL_NAMESPACE}" \
  --for=condition='Available' \
  --timeout='5m'

# Preparing Nodes
oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker'

# Create StorageCluster
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

# Wait for StorageCluster to be deployed
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
   -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='10m'

echo "ODF/OCS Operator is deployed successfully"
