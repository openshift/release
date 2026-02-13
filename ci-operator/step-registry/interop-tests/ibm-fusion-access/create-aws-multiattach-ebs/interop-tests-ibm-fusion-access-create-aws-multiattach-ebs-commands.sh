#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
	source "${SHARED_DIR}/proxy-conf.sh"
fi

volumeSize="${FA__EXTRA_DISKS_SIZE:-100}"
volumeIops="${FA__EXTRA_DISKS_IOPS:-3000}"
volumeType="io2"

: 'Creating multi-attach io2 EBS volume for IBM Storage Scale shared storage...'

infrastructureName=$(oc get infrastructures cluster -o json | jq -r .status.infrastructureName)

if [ "${FA__NODE_ROLE}" == "all" ]; then
  nodes=$(oc get nodes --no-headers | awk '{print $1}')
else
  nodes=$(oc get nodes --no-headers -l "node-role.kubernetes.io/${FA__NODE_ROLE}" | awk '{print $1}')
fi

nodeArray=($nodes)
nodeCount=${#nodeArray[@]}

if [[ $nodeCount -lt 1 ]]; then
  : "ERROR: No nodes found with role ${FA__NODE_ROLE}"
  exit 1
fi

: "Found ${nodeCount} nodes with role ${FA__NODE_ROLE}"

firstNode=${nodeArray[0]}
region=$(oc get node "${firstNode}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/region"')
availabilityZone=$(oc get node "${firstNode}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/zone"')

: "Using availability zone: ${availabilityZone}"

for node in "${nodeArray[@]}"; do
  nodeAZ=$(oc get node "${node}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/zone"')
  if [[ "${nodeAZ}" != "${availabilityZone}" ]]; then
    : "ERROR: Node ${node} is in AZ ${nodeAZ}, but first node is in ${availabilityZone}"
    : 'Multi-attach EBS requires all nodes to be in the same availability zone.'
    exit 1
  fi
done

: 'All nodes are in the same availability zone. Proceeding...'

volName="${infrastructureName}-shared-san-$(date '+%Y%m%d%H%M%S')"
tags="ResourceType=volume,Tags=[{Key=kubernetes.io/cluster/${infrastructureName},Value=owned},{Key=Name,Value=${volName}},{Key=Purpose,Value=ibm-storage-scale-shared}]"

: 'Creating multi-attach io2 volume...'
volumeId=$(aws ec2 create-volume \
  --region "${region}" \
  --availability-zone "${availabilityZone}" \
  --size "${volumeSize}" \
  --volume-type "${volumeType}" \
  --iops "${volumeIops}" \
  --multi-attach-enabled \
  --tag-specifications "${tags}" \
  --query VolumeId \
  --output text)

if [[ -z "${volumeId}" || "${volumeId}" == "null" ]]; then
  : 'ERROR: Failed to create volume'
  exit 1
fi

: "Created volume: ${volumeId}"

: 'Waiting for volume to become available...'
if aws ec2 wait volume-available --region "${region}" --volume-ids "${volumeId}"; then
  : 'Volume is available'
else
  : 'ERROR: Volume did not become available'
  exit 1
fi

: "Attaching volume to all ${nodeCount} worker nodes..."

fullDeviceList="sdp sdo sdn sdm sdl sdk sdj sdi sdh sdg sdf"

for node in "${nodeArray[@]}"; do
  instanceId=$(oc get node "${node}" -o json | jq -r .spec.providerID | awk -F "/" '{print $NF}')
  : "Attaching to node ${node} (instance ${instanceId})..."
  
  existingDevices=$(aws ec2 describe-instances --region "${region}" --instance-ids "${instanceId}" --query 'Reservations[0].Instances[0].BlockDeviceMappings[].DeviceName' --output text)
  
  deviceName=""
  for device in ${fullDeviceList}; do
    if ! echo "${existingDevices}" | grep -q "${device}"; then
      deviceName="/dev/${device}"
      break
    fi
  done
  
  if [[ -z "${deviceName}" ]]; then
    : "ERROR: No available device name for ${node}"
    exit 1
  fi
  
  : "  Using device: ${deviceName}"
  
  aws ec2 attach-volume --region "${region}" --device "${deviceName}" --instance-id "${instanceId}" --volume-id "${volumeId}"
  
  if aws ec2 wait volume-in-use --region "${region}" --volume-ids "${volumeId}"; then
    : "  Attached successfully to ${node}"
  else
    : "  ERROR: Volume attachment timed out for ${node}"
    exit 1
  fi
done

: 'Triggering PCI bus rescan on all nodes (required for bare metal NVMe hotplug)...'
for node in "${nodeArray[@]}"; do
  : "  Rescanning PCI bus on ${node}..."
  if ! oc debug -n default node/"${node}" --quiet -- chroot /host bash -c 'echo 1 > /sys/bus/pci/rescan'; then
    : "PCI rescan failed on ${node}, continuing"
  fi
done

: 'Saving volume ID to SHARED_DIR for cleanup...'
echo "${volumeId}" > "${SHARED_DIR}/multiattach-volume-id"

volumeIdClean="${volumeId//-/}"
deviceById="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volumeIdClean}"
echo "${deviceById}" > "${SHARED_DIR}/ebs-device-path"

: "Verifying device visibility on ${firstNode}..."
verifyTimeout=180
verifyElapsed=0
while [[ $verifyElapsed -lt $verifyTimeout ]]; do
  if oc debug -n default node/"${firstNode}" --quiet -- chroot /host ls "${deviceById}" >/dev/null; then
    : "Device ${deviceById} is visible on ${firstNode}"
    break
  fi
  # sleep required: polling host device visibility has no oc wait equivalent
  sleep 10
  verifyElapsed=$((verifyElapsed + 10))
  : "  Waiting for device to appear... (${verifyElapsed}/${verifyTimeout}s)"
done

if [[ $verifyElapsed -ge $verifyTimeout ]]; then
  : "ERROR: Device not found at expected path ${deviceById}"
  : 'Diagnostic information'
  : "Block devices on ${firstNode}:"
  if ! oc debug -n default node/"${firstNode}" --quiet -- chroot /host lsblk -o NAME,SIZE,MODEL,SERIAL; then
    : 'lsblk failed'
  fi
  : 'Available NVMe devices in /dev/disk/by-id/:'
  if ! oc debug -n default node/"${firstNode}" --quiet -- chroot /host ls -la /dev/disk/by-id/ | grep -i nvme; then
    : 'No NVMe devices found'
  fi
  : 'All /dev/disk/by-id/ entries:'
  if ! oc debug -n default node/"${firstNode}" --quiet -- chroot /host ls -la /dev/disk/by-id/; then
    : 'Failed to list /dev/disk/by-id/'
  fi
  exit 1
fi

: 'Multi-attach EBS volume setup complete'

