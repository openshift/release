#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${SHARED_DIR}/nutanix_context.sh

echo "$(date -u --rfc-3339=seconds) - Creating CSI manifests..."

cat > "${SHARED_DIR}/manifest_0001-nutanix-csi-ntnx-system-namespace.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ntnx-system
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
  source: certified-operators
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

oc apply -f "${SHARED_DIR}/manifest_0001-nutanix-csi-ntnx-system-namespace.yaml"
oc apply -f "${SHARED_DIR}/manifest_0002-nutanix-csi-ntnx-secret.yaml"
oc apply -f "${SHARED_DIR}/manifest_0003-nutanix-csi-operator-group.yaml"
oc apply -f "${SHARED_DIR}/manifest_0004-nutanix-csi-subscription.yaml"
oc apply -f "${SHARED_DIR}/manifest_0006-nutanix-csi-storage-class.yaml"

echo "$(date -u --rfc-3339=seconds) - Waiting for CSI operator to be available..."
sleep 60

oc -n ntnx-system get all
oc -n ntnx-system describe all
oc -n ntnx-system get events
oc -n ntnx-system get csv
oc -n ntnx-system describe csv -l operators.coreos.com/nutanixcsioperator.ntnx-system=
oc -n ntnx-system get subscription
oc -n ntnx-system describe subscription
oc get sc

if oc wait --for condition=Available=True --timeout=5m deployment/nutanix-csi-operator-controller-manager -n ntnx-system ; then
  echo "$(date -u --rfc-3339=seconds) - CSI operator controller manager is available"
fi

oc apply -f "${SHARED_DIR}/manifest_0005-nutanix-csi-storage.yaml"

sleep 60

oc -n ntnx-system get all
oc -n ntnx-system describe all
oc -n ntnx-system get events

if oc wait --for condition=Available=True --timeout=5m deployment/nutanix-csi-controller -n ntnx-system ; then
  echo "$(date -u --rfc-3339=seconds) - CSI operator is available"
fi

