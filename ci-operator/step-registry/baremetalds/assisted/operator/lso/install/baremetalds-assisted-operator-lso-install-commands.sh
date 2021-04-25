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

echo "Creating namespace 'openshift-local-storage'..."
oc adm new-project openshift-local-storage || true

oc annotate project openshift-local-storage openshift.io/node-selector=''

echo "Subscribing for local-storage-operator installation..."
cat <<EOCR | oc create -f -
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
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
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
  name: assisted-service
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
      storageClassName: assisted-service
      volumeMode: Filesystem
EOCR
EOF
