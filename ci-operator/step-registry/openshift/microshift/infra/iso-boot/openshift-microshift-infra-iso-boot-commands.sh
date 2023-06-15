#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

SSH_EXTERNAL_BASE_PORT=7000
API_EXTERNAL_BASE_PORT=6000

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

# number of VMs to create. This will change over time as we add more tests.
NUM_VMS=1
echo "${NUM_VMS}" > ${SHARED_DIR}/num_vms
for (( i=0; i<$NUM_VMS; i++ ))
do
  API_EXTERNAL_PORT=$((API_EXTERNAL_BASE_PORT+$i))
  SSH_EXTERNAL_PORT=$((SSH_EXTERNAL_BASE_PORT+$i))
  VM_NAME="ushift-${i}"
  cat <<EOF > /tmp/boot.sh
#!/bin/bash
set -xeuo pipefail
cd ~/microshift
./scripts/image-builder/create-vm.sh ${VM_NAME} default \$(find _output/image-builder -name "*.iso")
VMIPADDR=\$(./scripts/devenv-builder/manage-vm.sh ip -n ${VM_NAME})
timeout 5m bash -c "until ssh -oStrictHostKeyChecking=accept-new redhat@\${VMIPADDR} 'echo hello'; do sleep 5; done"
cat << EOF2 > /tmp/config.yaml
apiServer:
  subjectAltNames:
  - "${IP_ADDRESS}"
EOF2
scp /tmp/config.yaml "redhat@\${VMIPADDR}":/tmp/
set +e
ssh "redhat@\${VMIPADDR}" "sudo mv /tmp/config.yaml /etc/microshift/config.yaml && sudo reboot"
set -e
timeout 5m bash -c "until ssh redhat@\${VMIPADDR} 'echo hello'; do sleep 5; done"
timeout 5m bash -c "date; until ssh redhat@\${VMIPADDR} \"sudo systemctl status greenboot-healthcheck | grep 'active (exited)'\"; do sleep 5; done; date"

# Setup external access with port forwarding to allow running commands and tests from the CI container.
sudo /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \${VMIPADDR} --dport 6443 -j ACCEPT
sudo /sbin/iptables -t nat -I PREROUTING -p tcp --dport "${API_EXTERNAL_PORT}" -j DNAT --to \${VMIPADDR}:6443
sudo /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \${VMIPADDR} --dport 22 -j ACCEPT
sudo /sbin/iptables -t nat -I PREROUTING -p tcp --dport "${SSH_EXTERNAL_PORT}" -j DNAT --to \${VMIPADDR}:22
EOF
  chmod +x /tmp/boot.sh

  scp /tmp/boot.sh "${INSTANCE_PREFIX}:/tmp"
  ssh "${INSTANCE_PREFIX}" "/tmp/boot.sh"
  ssh "redhat@${IP_ADDRESS}" -p ${SSH_EXTERNAL_PORT} "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" > ${SHARED_DIR}/kubeconfig_${i}
  sed -i "s,:6443,:${API_EXTERNAL_PORT}," ${SHARED_DIR}/kubeconfig_${i}
  echo "${SSH_EXTERNAL_PORT}" > ${SHARED_DIR}/ssh_port_${i}
  echo "redhat" > ${SHARED_DIR}/user_${i}
done
