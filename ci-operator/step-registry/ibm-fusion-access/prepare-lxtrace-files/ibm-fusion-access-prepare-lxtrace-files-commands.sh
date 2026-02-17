#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Creating lxtrace dummy files on worker nodes...'

workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')

if [[ -z "${workerNodes}" ]]; then
  : 'ERROR: No worker nodes found'
  exit 1
fi

for node in $workerNodes; do
  : "Processing node: $node"
  
  oc debug -n default node/$node -- chroot /host bash -c 'touch /var/lib/firmware/lxtrace-dummy && chmod 644 /var/lib/firmware/lxtrace-dummy' 2>&1 | \
    grep -v "Starting pod\|Removing debug\|To use host" || true
  
  if oc debug -n default node/$node -- chroot /host test -f /var/lib/firmware/lxtrace-dummy >/dev/null; then
    : '  lxtrace-dummy created and verified'
  else
    : '  Failed to create lxtrace-dummy'
    exit 1
  fi
done

: 'lxtrace dummy files created on all worker nodes'

true
