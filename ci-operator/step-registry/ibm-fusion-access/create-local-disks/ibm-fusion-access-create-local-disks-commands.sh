#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Create LocalDisk resources for fixed NVMe devices on the first worker and wait for each object to appear in the API.
# Inputs: FA__SCALE__NAMESPACE (step ref env); cluster must have workers with NVMe devices as expected by the step.
# Non-obvious: Waits per LocalDisk with jsonpath metadata.name to match the interop shared-filesystem pattern.

typeset firstWorker=''
firstWorker=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath-as-json='{.items[*].metadata.name}' | jq -r 'first(.[]) // empty')
[[ -n "${firstWorker}" ]]

typeset -a deviceArr=("nvme2n1" "nvme3n1")
typeset -i diskIdx=0

for device in "${deviceArr[@]}"; do
  typeset localDiskName="shared-ebs-disk-${diskIdx}"

  {
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
      --arg name "${localDiskName}" \
      --arg ns "${FA__SCALE__NAMESPACE}" \
      --arg device "/dev/${device}" \
      --arg node "${firstWorker}" \
      '
        .metadata.name = $name |
        .metadata.namespace = $ns |
        .spec.device = $device |
        .spec.node = $node
      ' |
    yq -p json -o yaml eval .
  } 0<<'YAML' | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata: {}
spec:
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
YAML

  if ! oc wait --for=jsonpath='{.metadata.name}'="${localDiskName}" "localdisk/${localDiskName}" -n "${FA__SCALE__NAMESPACE}" --timeout=300s; then
    oc get localdisk "${localDiskName}" -n "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
    exit 1
  fi

  ((++diskIdx))
done

true

