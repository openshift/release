#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
TARGET_VM_NAME=$(cat ${SHARED_DIR}/target_vm_name)
target_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/gather_target_lca.sh
#!/bin/bash
set -xeuo pipefail

# Setup directories for data
cd ${remote_workdir}
gather_dir=./must-gather-lca-${TARGET_VM_NAME}

export KUBECONFIG=${target_kubeconfig}

# Inspect the namespace
oc adm must-gather --image=${LCA_PULL_REF} --dest-dir=\$gather_dir

echo "compressing must gather contents..."
sudo tar cvaf must-gather-lca-${TARGET_VM_NAME}.tar.gz \$gather_dir
EOF

chmod +x ${SHARED_DIR}/gather_target_lca.sh

echo "Transfering gather LCA script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_target_lca.sh $ssh_host_ip:$remote_workdir

echo "Gather target LCA..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_target_lca.sh"

echo "Pulling must gather data from the host..."
scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/must-gather-lca-${TARGET_VM_NAME}.tar.gz ${ARTIFACT_DIR}