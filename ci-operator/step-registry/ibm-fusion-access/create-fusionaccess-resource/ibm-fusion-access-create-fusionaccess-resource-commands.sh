#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc create -f - --dry-run=client -o json --save-config <<EOF | oc apply -f -
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: ${FA__NAMESPACE}
spec:
  storageScaleVersion: ${FA__STORAGE_SCALE_VERSION}
  storageDeviceDiscovery:
    create: true
EOF

true
