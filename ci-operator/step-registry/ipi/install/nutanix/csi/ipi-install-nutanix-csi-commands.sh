#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${SHARED_DIR}/nutanix_context.sh

echo "$(date -u --rfc-3339=seconds) - Creating CSI manifests..."

cat > "${SHARED_DIR}/manifest_0000-nutanix-csi-ntnx-system-namespace.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ntnx-system
EOF

cat > "${SHARED_DIR}/manifest_0001-nutanix-csi-operator-beta-catalog-source.yaml" << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: nutanix-csi-operator-beta
  namespace: openshift-marketplace
spec:
  displayName: Nutanix Beta
  publisher: Nutanix-dev
  sourceType: grpc
  image: quay.io/ntnx-csi/nutanix-csi-operator-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 5m
EOF

cat > "${SHARED_DIR}/manifest_0002-nutanix-csi-ntnx-secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ntnx-secret
  namespace: ntnx-system
stringData:
  key: ${PE_HOST}:${PE_PORT}:${PE_USERNAME}:${PE_PASSWORD}
EOF

cat > "${SHARED_DIR}/manifest_0003-nutanix-csi-operator-group.yaml" << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ntnx-system-r8czl
  namespace: ntnx-system
spec:
  targetNamespaces:
    - ntnx-system
EOF

cat > "${SHARED_DIR}/manifest_0004-nutanix-csi-subscription.yaml" << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nutanixcsioperator
  namespace: ntnx-system
spec:
  channel: stable
  name: nutanixcsioperator
  installPlanApproval: Automatic
  source: nutanix-csi-operator-beta
  sourceNamespace: openshift-marketplace
EOF

cat > "${SHARED_DIR}/manifest_0005-nutanix-csi-storage.yaml" << EOF
apiVersion: crd.nutanix.com/v1alpha1
kind: NutanixCsiStorage
metadata:
  name: nutanixcsistorage
  namespace: ntnx-system
spec:
  namespace: ntnx-system
  tolerations:
    - key: "node-role.kubernetes.io/infra"
      operator: "Exists"
      value: ""
      effect: "NoSchedule"
EOF

cat > "${SHARED_DIR}/manifest_0006-nutanix-csi-storage-class.yaml" << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nutanix-volume
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.nutanix.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: ntnx-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ntnx-system
  csi.storage.k8s.io/node-publish-secret-name: ntnx-secret
  csi.storage.k8s.io/node-publish-secret-namespace: ntnx-system
  csi.storage.k8s.io/controller-expand-secret-name: ntnx-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ntnx-system
  csi.storage.k8s.io/fstype: ext4
  storageContainer: ${PE_STORAGE_CONTAINER}
  storageType: NutanixVolumes
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

oc apply -f "${SHARED_DIR}/manifest_0000-nutanix-csi-ntnx-system-namespace.yaml"
oc apply -f "${SHARED_DIR}/manifest_0001-nutanix-csi-operator-beta-catalog-source.yaml"
oc apply -f "${SHARED_DIR}/manifest_0002-nutanix-csi-ntnx-secret.yaml"
oc apply -f "${SHARED_DIR}/manifest_0003-nutanix-csi-operator-group.yaml"
oc apply -f "${SHARED_DIR}/manifest_0004-nutanix-csi-subscription.yaml"
oc apply -f "${SHARED_DIR}/manifest_0006-nutanix-csi-storage-class.yaml"

wait_for_resource() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3
  local timeout=$4
  local interval=$5

  local end_time=$(( $(date +%s) + $timeout ))

  # Wait for the resource to be created
  while [ "$(date +%s)" -lt $end_time ]; do
    if [ -n "$(kubectl get $resource_type $resource_name -n $namespace --no-headers --ignore-not-found 2>/dev/null)" ]; then
      break
    fi
    sleep $interval
  done

  if [ "$(date +%s)" -ge $end_time ]; then
    echo "Timed out waiting for $resource_type $resource_name to be created in namespace $namespace."
    echo "$(date -u --rfc-3339=seconds) - Checking CSI manifests..."
    oc -n ntnx-system get all
    oc -n ntnx-system describe all
    oc -n ntnx-system get events
    oc -n ntnx-system get csv
    oc -n ntnx-system describe csv -l operators.coreos.com/nutanixcsioperator.ntnx-system=
    oc -n ntnx-system get subscription
    oc -n ntnx-system describe subscription
    oc get sc
    exit 1
  fi

  # Wait for the resource to be available/established
  local condition="Available"
  if [ "$resource_type" == "crd" ]; then
    condition="Established"
  fi
  kubectl wait --for=condition=$condition $resource_type/$resource_name -n $namespace --timeout=$timeout"s"
}

# Customize these variables as needed
crd_name="nutanixcsistorages.crd.nutanix.com"
deployment_name="nutanix-csi-controller"
namespace="ntnx-system"
timeout=300  # 5 minutes in seconds
interval=10  # Check every 10 seconds

# Wait for the CRD
echo "Waiting for CRD $crd_name..."
wait_for_resource "crd" $crd_name "" $timeout $interval

oc apply -f "${SHARED_DIR}/manifest_0005-nutanix-csi-storage.yaml"

# Wait for the Deployment
echo "Waiting for Deployment $deployment_name in namespace $namespace..."
wait_for_resource "deployment" $deployment_name $namespace $timeout $interval
