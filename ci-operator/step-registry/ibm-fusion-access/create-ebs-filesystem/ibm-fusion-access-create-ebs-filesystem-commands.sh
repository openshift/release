#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Create the IBM Storage Scale Filesystem CR that references shared disks and wait until the filesystem is ready.
# Inputs: FA__SCALE__NAMESPACE, FA__SCALE__FILESYSTEM_READY_TIMEOUT (step ref env).
# Non-obvious: Uses oc wait for the Filesystem resource with a configurable timeout.

{
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__SCALE__NAMESPACE}" '.metadata.namespace = $ns' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
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
YAML

if ! oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
  filesystem/shared-filesystem \
  -n "${FA__SCALE__NAMESPACE}" \
  --timeout="${FA__SCALE__FILESYSTEM_READY_TIMEOUT}"; then
  oc get filesystem shared-filesystem -n "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

true
