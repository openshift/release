#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

typeset firstWorker=''
firstWorker=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${firstWorker}" ]]; then
  oc get nodes
  exit 1
fi

typeset -a devices=("nvme2n1" "nvme3n1")
typeset diskCount=0

for device in "${devices[@]}"; do
  typeset localdiskName="shared-ebs-disk-${diskCount}"
  
  oc create -f - --dry-run=client -o json --save-config <<EOF | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: ${localdiskName}
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  device: /dev/${device}
  node: ${firstWorker}
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
EOF
  
  diskCount=$((diskCount + 1))
done

true
