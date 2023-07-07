#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

# May need to update openshift-microshift-infra-aws-ec2-commands.sh to
# open other ports if changing these settings.
SSH_EXTERNAL_BASE_PORT=7000
API_EXTERNAL_BASE_PORT=7100
LB_EXTERNAL_BASE_PORT=7500

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

#TODO commenting for speed.
# # Number of VMs to create.
# # This will change over time as we add more tests.
# NUM_VMS=3
# echo "${NUM_VMS}" > "${SHARED_DIR}/num_vms"

# # Run the boot VM loop
# # TODO: run the boot.sh script in parallel
# # Note that 'dnf' command fails when in parallel, so it needs to be put in
# # critical section in the scripts/image-builder/create-vm.sh script
# for (( i=0; i<NUM_VMS; i++ ))
# do
#   API_EXTERNAL_PORT=$((API_EXTERNAL_BASE_PORT+i))
#   SSH_EXTERNAL_PORT=$((SSH_EXTERNAL_BASE_PORT+i))
#   VM_NAME="ushift-${i}"
#   cat <<EOF > /tmp/boot.sh
# #!/bin/bash
# set -xeuo pipefail

# cd ~/microshift

# ISO_FILE=\$(find ~/microshift/_output/image-builder -name "*.iso")
# sudo bash -c " \
#   cd /var/lib/libvirt/images/ && \
#   virt-install \
#       --name ${VM_NAME} \
#       --vcpus 2 \
#       --memory 3072 \
#       --disk path=./${VM_NAME}.qcow2,size=20 \
#       --network network=default,model=virtio \
#       --events on_reboot=restart \
#       --cdrom "\${ISO_FILE}" \
#       --noautoconsole \
#       --wait \
# "

# VM_IP=\$(./scripts/devenv-builder/manage-vm.sh ip -n ${VM_NAME})
# timeout 8m bash -c "until ssh -oStrictHostKeyChecking=accept-new redhat@\${VM_IP} 'echo hello'; do sleep 5; done"

# cat << EOF2 > /tmp/config.yaml
# apiServer:
#   subjectAltNames:
#   - "${IP_ADDRESS}"
# EOF2

# scp /tmp/config.yaml "redhat@\${VM_IP}":/tmp/
# set +e
# ssh "redhat@\${VM_IP}" "sudo mv /tmp/config.yaml /etc/microshift/config.yaml && sudo reboot"
# set -e
# EOF

#   chmod +x /tmp/boot.sh
#   scp /tmp/boot.sh "${INSTANCE_PREFIX}:/tmp"
#   ssh "${INSTANCE_PREFIX}" "/tmp/boot.sh"
# done

# # Run the wait VM loop
# for (( i=0; i<NUM_VMS; i++ ))
# do
#   API_EXTERNAL_PORT=$((API_EXTERNAL_BASE_PORT+i))
#   SSH_EXTERNAL_PORT=$((SSH_EXTERNAL_BASE_PORT+i))
#   VM_NAME="ushift-${i}"

# cat <<EOF > /tmp/wait.sh
# #!/bin/bash
# set -xeuo pipefail

# cd ~/microshift
# VM_IP=\$(./scripts/devenv-builder/manage-vm.sh ip -n ${VM_NAME})

# timeout 8m bash -c "until ssh redhat@\${VM_IP} hostname; do sleep 5; done"
# timeout 8m bash -c "date; until ssh redhat@\${VM_IP} \"sudo systemctl status greenboot-healthcheck | grep 'active (exited)'\"; do sleep 5; done; date"

# # Setup external access with port forwarding to allow running commands and tests from the CI container.
# sudo /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \${VM_IP} --dport 6443 -j ACCEPT
# sudo /sbin/iptables -t nat -I PREROUTING -p tcp --dport "${API_EXTERNAL_PORT}" -j DNAT --to \${VM_IP}:6443
# sudo /sbin/iptables -I FORWARD -o virbr0 -p tcp -d \${VM_IP} --dport 22 -j ACCEPT
# sudo /sbin/iptables -t nat -I PREROUTING -p tcp --dport "${SSH_EXTERNAL_PORT}" -j DNAT --to \${VM_IP}:22
# EOF

#   chmod +x /tmp/wait.sh
#   scp /tmp/wait.sh "${INSTANCE_PREFIX}:/tmp"
#   ssh "${INSTANCE_PREFIX}" "/tmp/wait.sh"
# done

# # Save the name, ip, port, user, etc. information about the VMs
# for (( i=0; i<NUM_VMS; i++ ))
# do
#   API_EXTERNAL_PORT=$((API_EXTERNAL_BASE_PORT+i))
#   SSH_EXTERNAL_PORT=$((SSH_EXTERNAL_BASE_PORT+i))
#   VM_NAME="ushift-${i}"

#   ssh "redhat@${IP_ADDRESS}" -p ${SSH_EXTERNAL_PORT} \
#     "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" > "${SHARED_DIR}/kubeconfig_${i}"
#   sed -i "s,:6443,:${API_EXTERNAL_PORT}," "${SHARED_DIR}/kubeconfig_${i}"

#   # shellcheck disable=SC2029
#   ssh "${INSTANCE_PREFIX}" \
#     "microshift/scripts/devenv-builder/manage-vm.sh ip -n ${VM_NAME}" > "${SHARED_DIR}/vm_int_ip_${i}"

#   echo "${VM_NAME}" > "${SHARED_DIR}/vm_ssh_host_${i}"
#   echo "${SSH_EXTERNAL_PORT}" > "${SHARED_DIR}/vm_ssh_port_${i}"
#   echo "redhat" > "${SHARED_DIR}/vm_user_${i}"
# done

# Install the settings for the scenario runner.  The ssh keys have
# already been copied into place in the iso-build step.
SETTINGS_FILE="${SHARED_DIR}/scenario_settings.sh"
cat <<EOF >"${SETTINGS_FILE}"
PUBLIC_IP=${IP_ADDRESS}
SSH_PUBLIC_KEY=~/.ssh/id_rsa.pub
SSH_PRIVATE_KEY=~/.ssh/id_rsa
EOF
scp "${SETTINGS_FILE}" "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/test/"

trap "scp -r ${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info ${ARTIFACT_DIR}" EXIT

# Run the in-repo ci phase script to create the VMs for the test scenarios.
ssh "${INSTANCE_PREFIX}" "/home/${HOST_USER}/microshift/test/bin/ci_phase_iso_boot.sh ${API_EXTERNAL_BASE_PORT} ${SSH_EXTERNAL_BASE_PORT} ${LB_EXTERNAL_BASE_PORT}"
