#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc label nodes -l node-role.kubernetes.io/worker= scale.spectrum.ibm.com/role=storage --overwrite

typeset -i labeledCount=0
labeledCount=$(oc get nodes -l scale.spectrum.ibm.com/role=storage -o jsonpath-as-json='{.items[*].metadata.name}' | jq 'length')
((labeledCount))

for node in $(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}'); do
  oc debug -n default "node/${node}" -- chroot /host bash -c '
    set -eux -o pipefail; shopt -s inherit_errexit
    mkdir -p /var/lib/firmware /var/mmfs/etc /var/mmfs/tmp/traces /var/mmfs/pmcollector
    touch /var/lib/firmware/lxtrace-dummy
    chmod 644 /var/lib/firmware/lxtrace-dummy
    true
  '
done

true
