#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')

if [[ -z "${workerNodes}" ]]; then
  exit 1
fi

for node in ${workerNodes}; do
  oc debug -n default "node/${node}" -- chroot /host bash -c 'touch /var/lib/firmware/lxtrace-dummy && chmod 644 /var/lib/firmware/lxtrace-dummy' 2>&1 | \
    grep -v "Starting pod\|Removing debug\|To use host" || true
  
  if ! oc debug -n default "node/${node}" -- chroot /host test -f /var/lib/firmware/lxtrace-dummy >/dev/null; then
    exit 1
  fi
done

true
