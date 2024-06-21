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

PULL_SECRET_FILE=$(cat ${SHARED_DIR}/pull_secret_file)
BACKUP_SECRET_FILE=$(cat ${SHARED_DIR}/backup_secret_file)
TARGET_VM_NAME="target"
remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
SEED_VERSION=$(cat ${SHARED_DIR}/seed_version)
TARGET_VERSION=$(cat ${SHARED_DIR}/target_version)
TARGET_IMAGE=$(cat ${SHARED_DIR}/target_image)
SEED_IMAGE_TAG=$(cat ${SHARED_DIR}/seed_tag)

echo "${TARGET_VM_NAME}" > "${SHARED_DIR}/target_vm_name"

echo "Creating upgrade script..."
cat <<EOF > ${SHARED_DIR}/upgrade_from_seed.sh
#!/bin/bash
set -euo pipefail

export PULL_SECRET=\$(<${PULL_SECRET_FILE})
export BACKUP_SECRET=\$(<${BACKUP_SECRET_FILE})
export TARGET_VM_NAME="${TARGET_VM_NAME}"
export TARGET_VERSION="${TARGET_VERSION}"
export RELEASE_IMAGE="${TARGET_IMAGE}"
export LCA_IMAGE="${LCA_PULL_REF}"
export SEED_VERSION="${SEED_VERSION}"
export UPGRADE_TIMEOUT="60m"

cd ${remote_workdir}/ib-orchestrate-vm

echo "Making a target cluster..."
make target

echo "Upgrading target cluster from ${TARGET_VERSION} to ${SEED_VERSION} using ${SEED_IMAGE}:${SEED_IMAGE_TAG}..."
make sno-upgrade SEED_IMAGE=${SEED_IMAGE}:${SEED_IMAGE_TAG} IBU_ROLLBACK=Disabled
EOF

chmod +x ${SHARED_DIR}/upgrade_from_seed.sh

echo "Transfering upgrade script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/upgrade_from_seed.sh $ssh_host_ip:$remote_workdir

echo "Upgrading target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/upgrade_from_seed.sh"
