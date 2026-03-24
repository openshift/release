#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

echo "Setting up SSD and NFS mounts for Additional Storage Configurations test"

# Get infrastructure name and region
infrastructureName=$(oc get infrastructures cluster -o json | jq -r .status.infrastructureName)
region=$(oc get infrastructures cluster -o json | jq -r .status.platformStatus.aws.region)

# Get first worker node
nodename=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | head -1 | awk '{print $1}')
instanceId=$(oc get node "${nodename}" -o json | jq -r .spec.providerID | awk -F "/" '{print $NF}')
availabilityZone=$(oc get node "${nodename}" -o json | jq -r '.metadata.labels."topology.kubernetes.io/zone"')

echo "Target node: ${nodename}"
echo "Instance ID: ${instanceId}"
echo "Availability Zone: ${availabilityZone}"

# Create EBS volume for SSD mount
volName=${nodename}-ssd-artifacts-$(date "+%Y%m%d%H%M%S")
tags="ResourceType=volume,Tags=[{Key=kubernetes.io/cluster/${infrastructureName},Value=owned},{Key=Name,Value=${volName}}]"

echo "Creating 50GB gp3 EBS volume for SSD artifacts..."
volumeId=$(aws ec2 create-volume \
  --region "${region}" \
  --availability-zone "${availabilityZone}" \
  --size 50 \
  --volume-type gp3 \
  --tag-specification "${tags}" \
  --query VolumeId \
  --output text)

echo "Created volume: ${volumeId}"

# Wait for volume to be available
echo "Waiting for volume to become available..."
aws ec2 wait volume-available --region "${region}" --volume-ids "${volumeId}"
echo "Volume ${volumeId} is available"

# Find available device name
echo "Finding available device name..."
deviceList=$(aws ec2 describe-instances --region "${region}" --instance-ids "${instanceId}" --query 'Reservations[0].Instances[0].BlockDeviceMappings[].DeviceName' --output text)
fullDeviceList="sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp"
deviceName=""
for device in ${fullDeviceList}; do
  if ! echo "${deviceList}" | grep -q "${device}"; then
    deviceName="/dev/$device"
    echo "Using device name: ${deviceName}"
    break
  fi
done

if [ "X${deviceName}" == "X" ]; then
  echo "No available device name found, exiting!" && exit 1
fi

# Attach volume
echo "Attaching volume ${volumeId} to instance ${instanceId} on ${deviceName}..."
aws ec2 attach-volume \
  --region "${region}" \
  --device "${deviceName}" \
  --instance-id "${instanceId}" \
  --volume-id "${volumeId}"

# Wait for attachment
echo "Waiting for volume to be attached..."
aws ec2 wait volume-in-use --region "${region}" --volume-ids "${volumeId}"
echo "Volume attached successfully"

# Format and mount SSD
echo "Formatting and mounting SSD volume..."
oc debug node/"${nodename}" -- chroot /host bash -c "
  # Wait for device to appear
  sleep 10

  # Format as XFS
  mkfs.xfs ${deviceName}

  # Create mount point
  mkdir -p /mnt/ssd-artifacts

  # Mount
  mount ${deviceName} /mnt/ssd-artifacts

  # Verify mount
  df -h | grep ssd-artifacts
"

echo "SSD volume mounted successfully at /mnt/ssd-artifacts"

# Setup NFS on the same node
echo "Setting up NFS server on ${nodename}..."
oc debug node/"${nodename}" -- chroot /host bash -c "
  # Install NFS server
  rpm-ostree install nfs-utils || echo 'nfs-utils may already be installed'

  # Create NFS export directory
  mkdir -p /var/nfs-share
  chmod 777 /var/nfs-share

  # Enable and start NFS server
  systemctl enable --now nfs-server rpcbind

  # Export the directory
  echo '/var/nfs-share *(rw,sync,no_root_squash)' > /etc/exports
  exportfs -ra

  # Verify NFS is running
  systemctl status nfs-server
  showmount -e localhost
"

echo "NFS server configured successfully"

# Get node IP for NFS mount
nodeIP=$(oc get node "${nodename}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "NFS server IP: ${nodeIP}"

# Mount NFS on the same node (for testing)
echo "Mounting NFS share on ${nodename}..."
oc debug node/"${nodename}" -- chroot /host bash -c "
  # Create mount point
  mkdir -p /mnt/nfs-artifacts

  # Mount NFS
  mount ${nodeIP}:/var/nfs-share /mnt/nfs-artifacts

  # Verify mount
  df -h | grep nfs-artifacts
"

echo "NFS share mounted successfully at /mnt/nfs-artifacts"

# Save info for cleanup
echo "${volumeId}" > "${SHARED_DIR}/ssd-volume-id"
echo "${nodename}" > "${SHARED_DIR}/storage-test-node"
echo "${nodeIP}" > "${SHARED_DIR}/nfs-server-ip"

echo "=========================================="
echo "Storage setup complete:"
echo "  SSD mounted at: /mnt/ssd-artifacts (${volumeId})"
echo "  NFS mounted at: /mnt/nfs-artifacts (${nodeIP}:/var/nfs-share)"
echo "  Test node: ${nodename}"
echo "=========================================="
