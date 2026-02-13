#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🏷️  Labeling worker nodes for IBM Storage Scale...'

# Label worker nodes for IBM Storage Scale (idempotent with --overwrite)
oc label nodes -l node-role.kubernetes.io/worker scale.spectrum.ibm.com/role=storage --overwrite

# Verify labeling
labeledCount=$(oc get nodes -l scale.spectrum.ibm.com/role=storage --no-headers | wc -l)

if [[ $labeledCount -eq 0 ]]; then
  : '❌ No nodes were labeled'
  exit 1
fi

: "✅ Labeled $labeledCount worker nodes for IBM Storage Scale"
oc get nodes -l scale.spectrum.ibm.com/role=storage

