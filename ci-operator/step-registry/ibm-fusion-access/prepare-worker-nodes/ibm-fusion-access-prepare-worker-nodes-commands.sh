#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

for node in $(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | awk '{print $1}'); do
  for dir in /var/lib/firmware /var/mmfs/etc /var/mmfs/tmp/traces /var/mmfs/pmcollector; do
    oc debug -n default "node/${node}" -- chroot /host mkdir -p "${dir}"
  done
done

true
