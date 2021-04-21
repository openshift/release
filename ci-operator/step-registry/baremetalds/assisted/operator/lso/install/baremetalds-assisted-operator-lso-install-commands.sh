#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup lso install command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

echo "Subscribing to local-storage-operator installation..."
cat <<EOCR | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
---
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
  - openshift-local-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: localstorage-operator-manifests
  namespace: openshift-local-storage
spec:
  sourceType: grpc
  image: quay.io/gnufied/gnufied-index:1.0.0
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-subscription
  namespace: openshift-local-storage
spec:
  channel: preview
  name: local-storage-operator
  source: localstorage-operator-manifests
  sourceNamespace: openshift-local-storage
EOCR

echo "Waiting for LocalVolume CRD to be defined..."
for i in {1..60}; do
    oc get crd/localvolumes.local.storage.openshift.io -n openshift-local-storage && break || sleep 10
done

echo "Waiting for LocalVolume CDR to become ready..."
oc -n openshift-local-storage wait --for condition=established --timeout=60s crd/localvolumes.local.storage.openshift.io

echo "Creating local volume and storage class..."
cat <<EOCR | oc create -f -
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: fs
  namespace: openshift-local-storage
spec:
  logLevel: Normal
  managementState: Managed
  storageClassDevices:
    - devicePaths:
        - /dev/sdb
        - /dev/sdc
        - /dev/sdd
        - /dev/sde
        - /dev/sdf
      fsType: ext4
      storageClassName: fs-lso
      volumeMode: Filesystem
EOCR
EOF
