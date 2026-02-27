#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

for node in $(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | awk '{print $1}'); do
  oc debug -n default "node/${node}" -- chroot /host bash -c 'touch /var/lib/firmware/lxtrace-dummy && chmod 644 /var/lib/firmware/lxtrace-dummy'
done

true
