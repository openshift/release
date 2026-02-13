#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🚀 Creating namespaces for Fusion Access Operator and IBM Storage Scale...'

# Set default values from environment variables
FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__OPERATOR_NAMESPACE="${FA__SCALE__OPERATOR_NAMESPACE:-ibm-spectrum-scale-operator}"

: "Fusion Access namespace: ${FA__NAMESPACE}"
: "Storage Scale namespace: ${FA__SCALE__NAMESPACE}"
: "Storage Scale Operator namespace: ${FA__SCALE__OPERATOR_NAMESPACE}"

# Create Fusion Access namespace
oc create namespace "${FA__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__NAMESPACE}" --timeout=60s

# Create IBM Storage Scale namespace
oc create namespace "${FA__SCALE__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__SCALE__NAMESPACE}" --timeout=60s

# Create IBM Storage Scale Operator namespace (required for kmm-image-config ConfigMap)
oc create namespace "${FA__SCALE__OPERATOR_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__SCALE__OPERATOR_NAMESPACE}" --timeout=60s

: 'Creating cross-namespace image push rolebinding for KMM builds...'
oc create rolebinding kmm-builder-push \
  --clusterrole=system:image-builder \
  --serviceaccount="${FA__NAMESPACE}:builder" \
  -n "${FA__SCALE__NAMESPACE}" \
  --dry-run=client -o yaml --save-config | oc apply -f -

: 'Namespace creation completed successfully'
: "  - ${FA__NAMESPACE}: $(oc get namespace "${FA__NAMESPACE}" -o jsonpath='{.status.phase}')"
: "  - ${FA__SCALE__NAMESPACE}: $(oc get namespace "${FA__SCALE__NAMESPACE}" -o jsonpath='{.status.phase}')"
: "  - ${FA__SCALE__OPERATOR_NAMESPACE}: $(oc get namespace "${FA__SCALE__OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}')"

