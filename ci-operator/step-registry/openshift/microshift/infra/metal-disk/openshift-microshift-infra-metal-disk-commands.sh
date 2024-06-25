#!/bin/bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") \011'

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

DISK_SCRIPT="/tmp/disk.sh"
cat <<EOF >"${DISK_SCRIPT}"
#!/bin/sh
set -xeuo pipefail

create_lv() {
  device=\$1

  sudo pvcreate /dev/\$device
  sudo vgcreate "vg\${device}" /dev/\$device
  lv_size=\$(sudo vgdisplay "vg\${device}" | grep "VG Size" | egrep -o "[[:digit:]]+\.[[:digit:]]+.*$" | awk '{print \$1\$2}' | sed 's/\.[0-9]\+//g')
  sudo lvcreate -L "\${lv_size}" -n "lv\${device}" "vg\${device}"
}

sudo dnf install -y jq lvm2 mdadm
tmp_device=\$(lsblk -J | jq -r '[.blockdevices[] | select(.children | length == 0)][0].name')
ushift_devices=\$(lsblk -J | jq -r '[.blockdevices[] | select(.children | length == 0)][1:] | map(.name) | join(" ")')

# Setup the /tmp directory
create_lv "\${tmp_device}"
sudo mkfs.xfs /dev/vg\${tmp_device}/lv\${tmp_device}
sudo mount /dev/vg\${tmp_device}/lv\${tmp_device} /tmp
sudo chmod 1777 /tmp
mv "\${HOME}"/.ssh /tmp

# Setup each of the volumes for the rest of the disks.
arr=(\$ushift_devices)
ndisks=\${#arr[@]}
device_paths=""
for device in \${ushift_devices}; do
  create_lv \$device
  device_paths="/dev/vg\$device/lv\$device \$device_paths"
  ndisks=\$((ndisks++))
done
sudo mdadm -C /dev/md0 -l raid0 -n \$ndisks \$device_paths
sudo mkfs.xfs /dev/md0
sudo mount /dev/md0 \${HOME}
sudo chown -R \$(id -u):\$(id -g) "\${HOME}"
mv /tmp/.ssh "\${HOME}"
df -h
ls -l /
ls -l /home/
sudo lsblk
sudo setenforce 0 || true
setenforce 0 || true

time sh -c "dd if=/dev/zero of=/home/ec2-user/testfile bs=1M count=2k conv=fdatasync && sync"
time sh -c "dd if=/dev/zero of=/tmp/testfile bs=1M count=2k conv=fdatasync && sync"
EOF
chmod +x "${DISK_SCRIPT}"
scp "${DISK_SCRIPT}" "${INSTANCE_PREFIX}:${DISK_SCRIPT}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM
ssh "${INSTANCE_PREFIX}" "${DISK_SCRIPT}" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
