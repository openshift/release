#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Label all worker nodes with the Storage Scale storage role and verify the expected worker count.
# Inputs: None beyond cluster access; relies on standard oc and node labels.
# Non-obvious: Counts workers via jsonpath-as-json and jq length per MPEX counting guidance.

oc label nodes -l node-role.kubernetes.io/worker= scale.spectrum.ibm.com/role=storage --overwrite

typeset -i labeledCount=0
labeledCount="$(
  oc get nodes \
    -l scale.spectrum.ibm.com/role=storage \
    -o jsonpath-as-json='{.items[*].metadata.name}' |
  jq 'length'
)"
if ! [[ "${labeledCount}" -ge 1 ]]; then
  oc get nodes -l scale.spectrum.ibm.com/role=storage -o yaml
  exit 1
fi

true
