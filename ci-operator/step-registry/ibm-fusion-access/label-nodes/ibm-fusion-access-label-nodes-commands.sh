#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Labeling worker nodes for IBM Storage Scale...'

oc label nodes -l node-role.kubernetes.io/worker scale.spectrum.ibm.com/role=storage --overwrite

LABELED_COUNT=$(oc get nodes -l scale.spectrum.ibm.com/role=storage --no-headers | wc -l)

if [[ $LABELED_COUNT -eq 0 ]]; then
  : 'No nodes were labeled'
  exit 1
fi

: "Labeled $LABELED_COUNT worker nodes for IBM Storage Scale"
oc get nodes -l scale.spectrum.ibm.com/role=storage
