#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Checking worker nodes...'

WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  : "WARNING: Only $WORKER_NODE_COUNT worker nodes (minimum 3 required for quorum)"
else
  : "Found $WORKER_NODE_COUNT worker nodes (quorum requirements met)"
fi

oc get nodes -l node-role.kubernetes.io/worker
