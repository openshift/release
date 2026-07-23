#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

{
  oc create -f - --dry-run=client -o json --save-config |
  jq --arg ns "${FA__SCALE__NAMESPACE}" '.metadata.namespace = $ns'
} 0<<'ocEOF' | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shared-ebs-disk-0
      - shared-ebs-disk-1
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
ocEOF

oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  filesystem/shared-filesystem \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__FILESYSTEM_READY_TIMEOUT}"

true
