#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

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
      '
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

  ((++diskIdx))
done

true

