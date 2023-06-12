#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
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

cat <<EOF > /tmp/boot.sh
#!/bin/bash
set -xeuo pipefail
cd ~/microshift
./scripts/image-builder/create-vm.sh edge default \$(find _output/image-builder -name "*.iso")
VMIPADDR=\$(./scripts/devenv-builder/manage-vm.sh ip -n edge)
timeout 5m bash -c "until ssh -oStrictHostKeyChecking=accept-new redhat@\${VMIPADDR} 'echo hello'; do sleep 5; done"
cat << EOF2 > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - "\${VMIPADDR}"
EOF2
scp /tmp/config.yaml "redhat@\${VMIPADDR}":/tmp/
set +e
ssh "redhat@\${VMIPADDR}" "sudo mv /tmp/config.yaml /etc/microshift/config.yaml; sudo reboot"
set -e
timeout 5m bash -c "until ssh -oStrictHostKeyChecking=accept-new redhat@\${VMIPADDR} 'echo hello'; do sleep 5; done"
timeout 5m bash -c "date; until ssh redhat@\${VMIPADDR} \"sudo systemctl status greenboot-healthcheck | grep 'active (exited)'\"; do sleep 5; done; date"
ssh "redhat@\${VMIPADDR}" "sudo cat /var/lib/microshift/resources/kubeadmin/\${VMIPADDR}/kubeconfig" > /tmp/kubeconfig
EOF
chmod +x /tmp/boot.sh

scp \
  /tmp/boot.sh \
  "${INSTANCE_PREFIX}:/tmp"
ssh "${INSTANCE_PREFIX}" "/tmp/boot.sh"