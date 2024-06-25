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
  devices=\$1
  vg_name=\$2
  lv_name=\$3
  vg_mount=\$4
  device_paths=""

  for device in \$devices; do
    sudo pvcreate /dev/\$device
    device_paths="\$(sudo pvdisplay /dev/\$device | grep "PV Name" | awk '{print \$3}') \$device_paths"
  done
  sudo vgcreate "\${vg_name}" \${device_paths}
  sudo vgdisplay "\${vg_name}"
  lv_size=\$(sudo vgdisplay "\${vg_name}" | grep "VG Size" | egrep -o "[[:digit:]]+\.[[:digit:]]+.*$" | awk '{print \$1\$2}' | sed 's/\.[0-9]\+//g')
  sudo lvcreate -L "\${lv_size}" -n "\${lv_name}" "\${vg_name}"
  sudo mkfs.xfs /dev/"\${vg_name}"/"\${lv_name}"
  sudo mkdir -p "\${vg_mount}"
  sudo mount /dev/"\${vg_name}"/"\${lv_name}" "\${vg_mount}"
}

sudo dnf install -y jq lvm2
tmp_device=\$(lsblk -J | jq -r '[.blockdevices[] | select(.children | length == 0)][0].name')
ushift_devices=\$(lsblk -J | jq -r '[.blockdevices[] | select(.children | length == 0)][1:] | map(.name) | join(" ")')

create_lv "\${tmp_device}" tmp tmp /tmp
sudo chmod 1777 /tmp
mv "\${HOME}"/.ssh /tmp
create_lv "\${ushift_devices}" ssd ssd "\${HOME}"
sudo chown -R \$(id -u):\$(id -g) "\${HOME}"
mv /tmp/.ssh "\${HOME}"
df -h
ls -l /
ls -l /home/
EOF
chmod +x "${DISK_SCRIPT}"
scp "${DISK_SCRIPT}" "${INSTANCE_PREFIX}:${DISK_SCRIPT}"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM
ssh "${INSTANCE_PREFIX}" "${DISK_SCRIPT}" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
