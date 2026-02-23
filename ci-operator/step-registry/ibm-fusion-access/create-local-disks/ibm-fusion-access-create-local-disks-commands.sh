#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

firstWorker=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${firstWorker}" ]]; then
  oc get nodes
  exit 1
fi

devices=("nvme2n1" "nvme3n1")
diskCount=0

for device in "${devices[@]}"; do
  localdiskName="shared-ebs-disk-${diskCount}"
  
  oc apply -f=- <<EOF
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
  
  oc wait --for=jsonpath='{.metadata.name}'="${localdiskName}" localdisk/"${localdiskName}" -n "${FA__SCALE__NAMESPACE}" --timeout=300s
  
  ((diskCount++))
done

oc get localdisk -n "${FA__SCALE__NAMESPACE}"

true
