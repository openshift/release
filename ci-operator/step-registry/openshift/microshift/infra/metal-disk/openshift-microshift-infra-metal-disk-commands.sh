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
VG_NAME="ssd"
LV_NAME="ssd"
MOUNT_DIR="\${HOME}/microshift"

sudo dnf install -y jq lvm2
devices=\$(lsblk -J | jq -r '.blockdevices[] | select(.children | length == 0) | .name')
device_paths=""

for device in \$devices; do
    sudo pvcreate /dev/\$device
    sudo pvdisplay /dev/\$device
    device_paths="\$(sudo pvdisplay /dev/\$device | grep "PV Name" | awk '{print \$3}') \$device_paths"
done

sudo vgcreate "\${VG_NAME}" \${device_paths}
sudo vgdisplay "\${VG_NAME}"

lv_size=\$(sudo vgdisplay "\${VG_NAME}" | grep "VG Size" | awk '{print \$3\$4}')
sudo lvcreate -L "\${lv_size}" -n "\${LV_NAME}" "\${VG_NAME}"
sudo lvdisplay /dev/"\${VG_NAME}"/"\${LV_NAME}"
sudo mkfs.xfs /dev/"\${VG_NAME}"/"\${LV_NAME}"

mkdir -p "\${MOUNT_DIR}"
sudo mount /dev/"\${VG_NAME}"/"\${LV_NAME}" "\${MOUNT_DIR}"
sudo chown -R \$(id -u):\$(id -g) "\${MOUNT_DIR}"
EOF
chmod +x "${DISK_SCRIPT}"
scp "${DISK_SCRIPT}" "${INSTANCE_PREFIX}:${DISK_SCRIPT}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM
ssh "${INSTANCE_PREFIX}" "${DISK_SCRIPT}" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
