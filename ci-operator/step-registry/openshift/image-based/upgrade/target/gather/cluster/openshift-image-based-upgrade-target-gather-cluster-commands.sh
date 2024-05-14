#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
TARGET_VM_NAME=$(cat ${SHARED_DIR}/target_vm_name)
target_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig

echo "Using Host $instance_ip"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/gather_target_cluster.sh
#!/bin/bash
set -euo pipefail

cd ${remote_workdir}
oc --kubeconfig ${target_kubeconfig} adm must-gather --dest-dir=./must-gather-cluster-${TARGET_VM_NAME}

tar cvaf must-gather-cluster-${TARGET_VM_NAME}.tar.gz ./must-gather-cluster-${TARGET_VM_NAME}
EOF

chmod +x ${SHARED_DIR}/gather_target_cluster.sh

echo "Transfering gather script..."
echo ${SHARED_DIR}
scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_target_cluster.sh $ssh_host_ip:$remote_workdir

echo "Gather target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_target_cluster.sh"

echo "Pulling must gather data from the host..."
scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/must-gather-cluster-${TARGET_VM_NAME}.tar.gz ${ARTIFACT_DIR}
