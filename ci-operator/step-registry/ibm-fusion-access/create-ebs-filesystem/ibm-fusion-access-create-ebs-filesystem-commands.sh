#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

cat > /tmp/filesystem-skeleton.yaml <<'SKELETON'
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
SKELETON

yq -o json /tmp/filesystem-skeleton.yaml | \
  jq --arg ns "${FA__SCALE__NAMESPACE}" '.metadata.namespace = $ns' | \
  oc create --dry-run=client -o json --save-config -f - | \
  oc apply -f -

oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  filesystem/shared-filesystem \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__FILESYSTEM_READY_TIMEOUT}"

true
