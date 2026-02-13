#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__LOCALDISK_NAME="${FA__LOCALDISK_NAME:-shared-san-disk}"

: 'Creating IBM Storage Scale LocalDisk resource (shared SAN architecture)'

workers=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

if [[ -z "${workers}" ]]; then
  : 'ERROR: No worker nodes found'
  oc get nodes
  exit 1
fi

workerArray=($workers)
workerCount=${#workerArray[@]}
firstWorker=${workerArray[0]}

: "Found ${workerCount} worker nodes"
: "Using ${firstWorker} as discovery node (shared disk visible to all workers)"

if [[ -f "${SHARED_DIR}/ebs-device-path" ]]; then
  byIdPath=$(cat "${SHARED_DIR}/ebs-device-path")
elif [[ -f "${SHARED_DIR}/multiattach-volume-id" ]]; then
  volumeId=$(cat "${SHARED_DIR}/multiattach-volume-id")
  volumeIdClean="${volumeId//-/}"
  byIdPath="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volumeIdClean}"
else
  : 'ERROR: No device path or volume ID found in SHARED_DIR'
  : 'This step requires create-aws-multiattach-ebs to run first'
  ls -la "${SHARED_DIR}/"
  exit 1
fi

devicePath=$(oc debug -n default node/"${firstWorker}" --quiet -- \
  chroot /host readlink -f "${byIdPath}" 2>&1 \
  | grep -v "Starting\|Removing\|To use")

if [[ -z "${devicePath}" || "${devicePath}" != /dev/* ]]; then
  : "ERROR: Failed to resolve device symlink on ${firstWorker}"
  : "  by-id path: ${byIdPath}"
  : "  resolved:   ${devicePath}"
  if ! oc debug -n default node/"${firstWorker}" --quiet -- \
      chroot /host ls -la "${byIdPath}"; then
    : 'Device NOT found'
  fi
  exit 1
fi

: "Creating shared LocalDisk: ${FA__LOCALDISK_NAME}"
oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: ${FA__LOCALDISK_NAME}
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  device: ${devicePath}
  node: ${firstWorker}
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
EOF

: "Waiting for LocalDisk ${FA__LOCALDISK_NAME} to become Ready..."

if oc wait --for=condition=Ready \
    localdisk/"${FA__LOCALDISK_NAME}" -n "${FA__SCALE__NAMESPACE}" --timeout=300s; then
  : "LocalDisk ${FA__LOCALDISK_NAME} is Ready"
else
  : 'ERROR: Timeout waiting for LocalDisk to become Ready'
  : 'Diagnostic information'
  : "Expected device path: ${devicePath}"
  : "Checking device visibility on ${firstWorker}..."
  if ! oc debug -n default node/"${firstWorker}" --quiet -- chroot /host ls -la "${devicePath}"; then
    : "Device NOT found at ${devicePath}"
  fi
  : "Available NVMe devices on ${firstWorker}:"
  if ! oc debug -n default node/"${firstWorker}" --quiet -- chroot /host ls -la /dev/disk/by-id/ | grep -i nvme; then
    : 'No NVMe devices found'
  fi
  : 'LocalDisk status:'
  oc get localdisk "${FA__LOCALDISK_NAME}" -n "${FA__SCALE__NAMESPACE}" -o yaml
  exit 1
fi

: 'LocalDisk configuration:'
oc get localdisk -n "${FA__SCALE__NAMESPACE}"

: 'Shared LocalDisk created successfully'

