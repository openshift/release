#!/bin/bash
set -euo pipefail

echo "************ openshift image based network configuration configure commands ************"

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/network-configuration.sh
#!/bin/bash
set -xeuo pipefail

cd ${remote_workdir}/ib-orchestrate-vm

# the IBI installed cluster use IP 192.168.127.74/24
make ipc \
  IPC_IPV4_ADDRESS=${IPC_IPV4_ADDRESS} \
  IPC_IPV4_MACHINE_NETWORK=${IPC_IPV4_MACHINE_NETWORK} \
  IPC_IPV4_GATEWAY=${IPC_IPV4_GATEWAY} \
  IPC_DNS_SERVERS=${IPC_DNS_SERVERS} \
  IPC_CLUSTER_NAME=${IPC_CLUSTER_NAME} \
  IBI_VM_NAME=${IBI_VM_NAME}

EOF

chmod +x ${SHARED_DIR}/network-configuration.sh

echo "Transfering network configuration script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/network-configuration.sh $ssh_host_ip:$remote_workdir

echo "Configure network configuration..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/network-configuration.sh"