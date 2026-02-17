#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Creating namespaces for IBM Fusion Access Operator and IBM Storage Scale'

oc create namespace "${FA__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__NAMESPACE}" --timeout=60s
oc create namespace "${FA__SCALE__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__SCALE__NAMESPACE}" --timeout=60s

: 'Namespace creation completed successfully'

true
