#!/bin/bash
set -euxo pipefail

echo "[INFO] Patching cluster scheduler to make master nodes schedulable..."
if ! oc patch Scheduler cluster --type='json' -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'; then
  echo "[ERROR] Failed to patch scheduler. This might indicate a problem with cluster permissions or an incompatible OpenShift version."
  exit 1
fi

echo "[SUCCESS] Cluster scheduler patched. Master nodes are now schedulable."
