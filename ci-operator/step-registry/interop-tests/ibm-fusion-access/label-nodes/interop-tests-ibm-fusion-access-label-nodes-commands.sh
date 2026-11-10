#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🏷️  Labeling worker nodes for IBM Storage Scale..."

# Label worker nodes for IBM Storage Scale (idempotent with --overwrite)
oc label nodes -l node-role.kubernetes.io/worker scale.spectrum.ibm.com/role=storage --overwrite

# Verify labeling
LABELED_COUNT=$(oc get nodes -l scale.spectrum.ibm.com/role=storage --no-headers | wc -l)

if [[ $LABELED_COUNT -eq 0 ]]; then
  echo "❌ No nodes were labeled"
  exit 1
fi

echo "✅ Labeled $LABELED_COUNT worker nodes for IBM Storage Scale"
oc get nodes -l scale.spectrum.ibm.com/role=storage
