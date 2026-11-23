#!/bin/bash
set -euo pipefail

echo "************ openshift image based network configuration gather commands ************"

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
remote_artifacts_dir="${remote_workdir}/ib-orchestrate-vm/ipc-workdir/artifacts"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/gather_network_configuration.sh
#!/bin/bash
set -xeuo pipefail

cd ${remote_workdir}/ib-orchestrate-vm

vm_artifacts_dir=ipc-workdir/artifacts/vm
mkdir -p "\${vm_artifacts_dir}"

# Host-side view of the VM, independent of whether it is reachable.
vnet=\$(sudo virsh domiflist ${IBI_VM_NAME} | awk '\$1 ~ /^vnet/ {print \$1; exit}' || true)
br_name=""
if [[ -n "\${vnet}" && -e "/sys/class/net/\${vnet}/master" ]]; then
  br_name=\$(basename "\$(readlink "/sys/class/net/\${vnet}/master")")
fi
sudo virsh domifaddr ${IBI_VM_NAME} --source arp > "\${vm_artifacts_dir}/domifaddr-arp.txt" 2>&1 || true
ip neigh show > "\${vm_artifacts_dir}/host-neigh.txt" 2>&1 || true
[[ -n "\${br_name}" ]] && bridge fdb show br "\${br_name}" > "\${vm_artifacts_dir}/bridge-fdb.txt" 2>&1 || true
sudo virsh screenshot ${IBI_VM_NAME} "\${vm_artifacts_dir}/console.ppm" > /dev/null 2>&1 || true
sudo chown -R "\$(id -u):\$(id -g)" "\${vm_artifacts_dir}" || true

# IPC recreates the libvirt network on the new subnet, leaving the host with no
# route to the node's original IP. Re-add the original gateway address so that
# ipc-gather's SSH fallback can reach a node that never moved off, or rolled
# back to, its original address.
if [[ -n "${IPC_ORIGINAL_IPV4_GATEWAY_CIDR}" && -n "\${br_name}" ]]; then
  sudo ip addr add "${IPC_ORIGINAL_IPV4_GATEWAY_CIDR}" dev "\${br_name}" || true
fi

# ipc-gather only tries the IPs it is given (plus the seed VM's) for SSH, so
# pass both the node's original and its target address.
make ipc-gather \
  IPC_CLUSTER_NAME=${IPC_CLUSTER_NAME} \
  IBI_VM_NAME=${IBI_VM_NAME} \
  IBI_VM_IP=${IBI_VM_IP} \
  IPC_IPV4_ADDRESS=${IPC_IPV4_ADDRESS}

# Full node journal and network state, which ipc-gather does not collect.
ssh_node=(ssh -o ConnectTimeout=5 -o IdentityFile=./bip-orchestrate-vm/ssh-key/key \
  -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)
for ip in ${IPC_IPV4_ADDRESS} ${IBI_VM_IP}; do
  if "\${ssh_node[@]}" "core@\${ip}" true; then
    node_dir=ipc-workdir/artifacts/node-ssh
    mkdir -p "\${node_dir}"
    echo "\${ip}" > "\${node_dir}/reached-ip.txt"
    "\${ssh_node[@]}" "core@\${ip}" 'sudo journalctl --list-boots --no-pager' > "\${node_dir}/boots.txt" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'sudo journalctl -b --no-pager' > "\${node_dir}/journal-current-boot.log" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'sudo journalctl -b -1 --no-pager' > "\${node_dir}/journal-previous-boot.log" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'ip addr; ip route; sudo nmcli -f all con show --active' > "\${node_dir}/network.txt" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'sudo ostree admin status; sudo rpm-ostree status' > "\${node_dir}/ostree.txt" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'sudo crictl ps -a' > "\${node_dir}/crictl-ps.txt" 2>&1 || true
    "\${ssh_node[@]}" "core@\${ip}" 'for c in \$(sudo crictl ps -a -q --label io.kubernetes.pod.namespace=openshift-lifecycle-agent); do echo "=== \$c"; sudo crictl logs \$c 2>&1; done' > "\${node_dir}/lca-containers.log" 2>&1 || true
    break
  fi
done

EOF

chmod +x ${SHARED_DIR}/gather_network_configuration.sh

echo "Transfering gather network configuration script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_network_configuration.sh $ssh_host_ip:$remote_workdir

echo "Gather network configuration..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_network_configuration.sh"

echo "Pulling ipc-gather artifacts from remote host..."
if ssh "${SSHOPTS[@]}" "$ssh_host_ip" "test -d '${remote_artifacts_dir}'"; then
  mkdir -p "${ARTIFACT_DIR}"
  scp -r "${SSHOPTS[@]}" "${ssh_host_ip}:${remote_artifacts_dir}" "${ARTIFACT_DIR}/ipc-workdir-artifacts"
else
  echo "No remote artifacts directory found at '${remote_artifacts_dir}', skipping artifact download."
fi