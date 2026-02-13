#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__STORAGE_SCALE_VERSION="${FA__STORAGE_SCALE_VERSION:-v5.2.3.5}"

: '🚀 Creating FusionAccess resource...'

# Check if FusionAccess resource already exists (idempotent)
if oc get fusionaccess fusionaccess-object -n "${FA__NAMESPACE}" >/dev/null; then
  : '✅ FusionAccess resource already exists'
else
  # Create FusionAccess resource
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
  
  : 'Waiting for FusionAccess resource to be created...'
  oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n ${FA__NAMESPACE} --timeout=600s
  
  : '✅ FusionAccess resource created successfully'
fi

# Show resource status
: 'FusionAccess resource status:'
oc get fusionaccess fusionaccess-object -n "${FA__NAMESPACE}"

