#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__FILESYSTEM_TIMEOUT="${FA__FILESYSTEM_TIMEOUT:-3600}"
FA__LOCALDISK_NAME="${FA__LOCALDISK_NAME:-shared-san-disk}"

: 'Creating IBM Storage Scale Filesystem on shared SAN storage (shared SAN architecture)'

if ! oc get localdisk "${FA__LOCALDISK_NAME}" -n ${FA__SCALE__NAMESPACE} >/dev/null; then
  : "ERROR: LocalDisk ${FA__LOCALDISK_NAME} not found"
  : 'Available LocalDisks:'
  oc get localdisk -n ${FA__SCALE__NAMESPACE} --ignore-not-found
  exit 1
fi

localdiskStatus=$(oc get localdisk "${FA__LOCALDISK_NAME}" -n ${FA__SCALE__NAMESPACE} \
  -o jsonpath='{.status.status}')

: "LocalDisk ${FA__LOCALDISK_NAME} status: ${localdiskStatus}"

: 'Creating Filesystem resource...'

oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - ${FA__LOCALDISK_NAME}
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF

: 'Filesystem resource created'
: "Waiting for Filesystem to become Established (up to $((FA__FILESYSTEM_TIMEOUT/60)) minutes)..."

if oc wait --for=condition=Success \
    filesystem/shared-filesystem -n "${FA__SCALE__NAMESPACE}" --timeout="${FA__FILESYSTEM_TIMEOUT}s"; then
  : 'Filesystem is Established'
else
  : 'ERROR: Timeout waiting for Filesystem to become Established'
  oc get filesystem shared-filesystem -n "${FA__SCALE__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

: 'Waiting for Filesystem to become Healthy...'

if oc wait --for=condition=Healthy \
    filesystem/shared-filesystem -n "${FA__SCALE__NAMESPACE}" --timeout=600s; then
  : 'Filesystem is Healthy'
else
  : 'WARNING: Filesystem Established but not Healthy within 600s'
  : 'Continuing -- CSI driver may still work with an Established filesystem'
fi

: 'Waiting for CSI driver to be ready...'

if oc wait --for=condition=Ready pod -l app=ibm-spectrum-scale-csi \
    -n ibm-spectrum-scale-csi --timeout=300s; then
  : 'CSI driver pods are running'
else
  : 'WARNING: CSI driver pods not detected within 300s'
  oc get pods -n ibm-spectrum-scale-csi --ignore-not-found
fi

oc get filesystem shared-filesystem -n ${FA__SCALE__NAMESPACE}

true
