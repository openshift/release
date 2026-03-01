#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc label nodes -l node-role.kubernetes.io/worker scale.spectrum.ibm.com/role=storage --overwrite

labeledCount=$(oc get nodes -l scale.spectrum.ibm.com/role=storage --no-headers | wc -l)

if [[ ${labeledCount} -eq 0 ]]; then
  exit 1
fi

oc get nodes -l scale.spectrum.ibm.com/role=storage

true
