#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Creating namespaces for IBM Fusion Access Operator and IBM Storage Scale'

fusionAccessNamespace="${FA__NAMESPACE:-ibm-fusion-access}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"

# Create IBM Fusion Access namespace
oc create namespace "${fusionAccessNamespace}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${fusionAccessNamespace}" --timeout=60s

# Create IBM Storage Scale namespace
oc create namespace "${FA__SCALE__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__SCALE__NAMESPACE}" --timeout=60s

: 'Namespace creation completed successfully'

