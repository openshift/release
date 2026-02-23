#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Checking worker nodes...'

workerNodeCount=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $workerNodeCount -lt 3 ]]; then
  : "WARNING: Only $workerNodeCount worker nodes (minimum 3 required for quorum)"
else
  : "Found $workerNodeCount worker nodes (quorum requirements met)"
fi

oc get nodes -l node-role.kubernetes.io/worker

true
