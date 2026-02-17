#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Creating FusionAccess resource...'

oc apply -f=- <<EOF
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

oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n "${FA__NAMESPACE}" --timeout=600s

oc get fusionaccess fusionaccess-object -n "${FA__NAMESPACE}"

true
