#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Create Fusion Access, Storage Scale, and operator namespaces plus required RoleBindings for the interop workflow.
# Inputs: FA__NAMESPACE, FA__SCALE__NAMESPACE, FA__SCALE__OPERATOR_NAMESPACE (step ref env).
# Non-obvious: Applies namespace and rolebinding manifests idempotently with oc apply.

# Create Fusion Access namespace
oc create namespace "${FA__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
if ! oc wait --for=create "namespace/${FA__NAMESPACE}" --timeout=60s; then
  oc get namespace "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

# Create IBM Storage Scale namespace
oc create namespace "${FA__SCALE__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
if ! oc wait --for=create "namespace/${FA__SCALE__NAMESPACE}" --timeout=60s; then
  oc get namespace "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

# Create IBM Storage Scale Operator namespace (required for kmm-image-config ConfigMap)
oc create namespace "${FA__SCALE__OPERATOR_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
if ! oc wait --for=create "namespace/${FA__SCALE__OPERATOR_NAMESPACE}" --timeout=60s; then
  oc get namespace "${FA__SCALE__OPERATOR_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

oc create rolebinding kmm-builder-push \
  --clusterrole=system:image-builder \
  --serviceaccount="${FA__NAMESPACE}:builder" \
  -n "${FA__SCALE__NAMESPACE}" \
  --dry-run=client -o yaml --save-config | oc apply -f -

true
