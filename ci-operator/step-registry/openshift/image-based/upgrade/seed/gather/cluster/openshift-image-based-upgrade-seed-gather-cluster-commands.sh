#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
SEED_VM_NAME=$(cat ${SHARED_DIR}/seed_vm_name)
seed_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${SEED_VM_NAME}/auth/kubeconfig

echo "Using Host $instance_ip"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

cat <<EOF > ${SHARED_DIR}/gather_seed_cluster.sh
#!/bin/bash
set -euo pipefail

cd ${remote_workdir}

# Download the MCO sanitizer binary from mirror
curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
chmod +x /tmp/mco-sanitize

oc --kubeconfig ${seed_kubeconfig} adm must-gather --dest-dir=./must-gather-cluster-${SEED_VM_NAME}

# Sanitize MCO resources to remove sensitive information.
# If the sanitizer fails, fall back to manual redaction.
if ! /tmp/mco-sanitize --input="./must-gather-cluster-${SEED_VM_NAME}"; then
  find "./must-gather-cluster-${SEED_VM_NAME}" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "\$1" && mv "\$1" "\$1.redacted"' _ {} \;
fi  

tar cvaf must-gather-cluster-${SEED_VM_NAME}.tar.gz ./must-gather-cluster-${SEED_VM_NAME}
EOF

chmod +x ${SHARED_DIR}/gather_seed_cluster.sh

echo "Transfering upgrade script..."
echo ${SHARED_DIR}
scp "${SSHOPTS[@]}" ${SHARED_DIR}/gather_seed_cluster.sh $ssh_host_ip:$remote_workdir

echo "Upgrading target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/gather_seed_cluster.sh"

echo "Pulling must gather data from the host..."
scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/must-gather-cluster-${SEED_VM_NAME}.tar.gz ${ARTIFACT_DIR}
