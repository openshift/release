#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

LCA_PULL_SECRET_FILE="/var/run/pull-secret/.dockerconfigjson"
CLUSTER_PULL_SECRET_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"
PULL_SECRET=$(cat ${CLUSTER_PULL_SECRET_FILE} ${LCA_PULL_SECRET_FILE} | jq -cs '.[0] * .[1]') # Merge the pull secrets to get everything we need
BACKUP_SECRET_FILE="/var/run/ibu-backup-secret/.backup-secret"
BACKUP_SECRET=$(jq -c . ${BACKUP_SECRET_FILE})
RECIPIENT_VM_NAME="recipient"
remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

SEED_IMAGE_TAG="pre-${PULL_PULL_SHA}"

echo "${RECIPIENT_VM_NAME}" > "${SHARED_DIR}/recipient_vm_name"

echo "Creating upgrade script..."
cat <<EOF > ${SHARED_DIR}/upgrade_from_seed.sh
#!/bin/bash
set -euo pipefail

export PULL_SECRET='${PULL_SECRET}'
export BACKUP_SECRET='${BACKUP_SECRET}'
export RECIPIENT_VM_NAME="${RECIPIENT_VM_NAME}"
export RECIPIENT_VERSION="${RECIPIENT_VERSION}"
export LCA_IMAGE="${LCA_PULL_REF}"
export SEED_VERSION="${SEED_VERSION}"
export UPGRADE_TIMEOUT="60m"

cd ${remote_workdir}/ib-orchestrate-vm

echo "Making a recipient cluster..."
make recipient

echo "Upgrading recipient cluster from ${RECIPIENT_VERSION} to ${SEED_VERSION} using ${SEED_IMAGE}:${SEED_IMAGE_TAG}..."
make sno-upgrade SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG}
EOF

chmod +x ${SHARED_DIR}/upgrade_from_seed.sh

echo "Transfering upgrade script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/upgrade_from_seed.sh $ssh_host_ip:$remote_workdir

echo "Upgrading recipient cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/upgrade_from_seed.sh"
