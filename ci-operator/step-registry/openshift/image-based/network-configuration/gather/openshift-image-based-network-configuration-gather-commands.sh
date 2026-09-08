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

make ipc-gather \
  IPC_CLUSTER_NAME=${IPC_CLUSTER_NAME} \
  IBI_VM_NAME=${IBI_VM_NAME}

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