#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Label workers for Storage Scale, prepare lxtrace directories on nodes via oc debug, and optionally seed dummy lxtrace logs when artifacts are missing.
# Inputs: Standard CI environment (oc, cluster); no FA__ prefix required for this step.
# Non-obvious: Uses oc debug chroot and in-node bash to create paths under /var/mmfs and /var/lib/firmware.

oc label nodes -l node-role.kubernetes.io/worker= scale.spectrum.ibm.com/role=storage --overwrite

typeset nodesJson=''
nodesJson="$(oc get nodes -l node-role.kubernetes.io/worker= -o json)"
typeset -i labeledCount=0
labeledCount=$(
  printf '%s' "${nodesJson}" |
    jq '[.items[] | select(.metadata.labels["scale.spectrum.ibm.com/role"] == "storage")] | length'
)
((labeledCount))

typeset node=''
while IFS= read -r node; do
  oc debug -n default "node/${node}" -- chroot /host bash -c '
    set -eux -o pipefail; shopt -s inherit_errexit
    mkdir -p /var/lib/firmware /var/mmfs/etc /var/mmfs/tmp/traces /var/mmfs/pmcollector
    touch /var/lib/firmware/lxtrace-dummy
    chmod 644 /var/lib/firmware/lxtrace-dummy
    true
  '
done < <(printf '%s' "${nodesJson}" | jq -r '.items[].metadata.name')

true
