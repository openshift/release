#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source ${SHARED_DIR}/nutanix_context.sh


echo "$(date -u --rfc-3339=seconds) - Creating CSI manifests..."
cat > "${SHARED_DIR}/manifest_0000-nutanix-csi-crd-manifest.yaml" << EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: nutanixcsistorages.crd.nutanix.com
spec:
  group: crd.nutanix.com
  names:
    kind: NutanixCsiStorage
    listKind: NutanixCsiStorageList
    plural: nutanixcsistorages
    singular: nutanixcsistorage
  scope: Namespaced
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        description: NutanixCsiStorage is the Schema for the nutanixcsistorages API
        properties:
          apiVersion:
            description: 'APIVersion defines the versioned schema of this representation
              of an object. Servers should convert recognized schemas to the latest
              internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
            type: string
          kind:
            description: 'Kind is a string value representing the REST resource this
              object represents. Servers may infer this from the endpoint the client
              submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
            type: string
          metadata:
            type: object
          spec:
            description: Spec defines the desired state of NutanixCsiStorage
            type: object
            x-kubernetes-preserve-unknown-fields: true
          status:
            description: Status defines the observed state of NutanixCsiStorage
            type: object
            x-kubernetes-preserve-unknown-fields: true
        type: object
    served: true
    storage: true
    subresources:
      status: {}
EOF

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