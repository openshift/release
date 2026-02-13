#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

fusionAccessNamespace="${FA__NAMESPACE:-ibm-fusion-access}"
fusionAccessStorageScaleVersion="${FA__STORAGE_SCALE_VERSION:-5.2.3.1}"

: 'Creating FusionAccess resource...'

if oc get fusionaccess fusionaccess-object -n "${fusionAccessNamespace}" >/dev/null; then
  : 'FusionAccess resource already exists'
else
  oc apply -f=- <<EOF
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: ${fusionAccessNamespace}
spec:
  storageScaleVersion: ${fusionAccessStorageScaleVersion}
  storageDeviceDiscovery:
    create: true
EOF
  
  : 'Waiting for FusionAccess resource to be created...'
  oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n ${fusionAccessNamespace} --timeout=600s
  
  : 'FusionAccess resource created successfully'
fi

oc get fusionaccess fusionaccess-object -n "${fusionAccessNamespace}"
