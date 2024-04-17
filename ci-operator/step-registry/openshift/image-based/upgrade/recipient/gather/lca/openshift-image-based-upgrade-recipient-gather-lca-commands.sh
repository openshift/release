#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
RECIPIENT_VM_NAME=$(cat ${SHARED_DIR}/recipient_vm_name)
recipient_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${RECIPIENT_VM_NAME}/auth/kubeconfig

echo "Using Host $instance_ip"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/gather_recipient_lca.sh
#!/bin/bash
set -euo pipefail

# Setup directories for data
cd ${remote_workdir}
gather_dir=./must-gather-lca-${RECIPIENT_VM_NAME}
gather_dir_extra=./must-gather-lca-${RECIPIENT_VM_NAME}/extra
mkdir -p \$gather_dir_extra

export KUBECONFIG=${recipient_kubeconfig}

# Inspect the namespace
oc adm inspect ns/openshift-lifecycle-agent --dest-dir=\$gather_dir

# Get installation service logs and recert summary files
node="\$(oc get nodes -oname)"

oc debug \$node -qn openshift-cluster-node-tuning-operator -- chroot /host/ bash -c 'journalctl -u installation-configuration.service' > \$gather_dir_extra/installation-configuration.service.log

tar cvaf must-gather-lca-${RECIPIENT_VM_NAME}.tar.gz \$gather_dir
EOF

chmod +x ${SHARED_DIR}/gather_recipient_lca.sh

echo "Transfering gather LCA script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_recipient_lca.sh $ssh_host_ip:$remote_workdir

echo "Gather recipient LCA..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_recipient_lca.sh"

echo "Pulling must gather data from the host..."
scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/must-gather-lca-${RECIPIENT_VM_NAME}.tar.gz ${ARTIFACT_DIR}