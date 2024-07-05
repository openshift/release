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
remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"

TARGET_VM_NAME="target"
echo "${TARGET_VM_NAME}" > "${SHARED_DIR}/target_vm_name"

SEED_VERSION=$(cat ${SHARED_DIR}/seed_version)
SEED_IMAGE_TAG=$(cat ${SHARED_DIR}/seed_tag)
SEED_IMAGE="${SEED_IMAGE}:${SEED_IMAGE_TAG}"

# Save the pull secrets
echo -n "${PULL_SECRET}" > ${SHARED_DIR}/.pull_secret.json
echo -n "${BACKUP_SECRET}" > ${SHARED_DIR}/.backup_secret.json

echo "Creating upgrade script..."
cat <<EOF > ${SHARED_DIR}/image_based_install.sh
#!/bin/bash
set -euo pipefail

export SEED_IMAGE="${SEED_IMAGE}"
export SEED_VERSION="${SEED_VERSION}"
export LCA_IMAGE="${LCA_PULL_REF}"
export IBI_VM_NAME="${TARGET_VM_NAME}"

cd ${remote_workdir}/ib-orchestrate-vm

export REGISTRY_AUTH_FILE='${remote_workdir}/.pull_secret.json'
export PULL_SECRET=\$(<\$REGISTRY_AUTH_FILE)
export BACKUP_SECRET=\$(<${remote_workdir}/.backup_secret.json)

sudo dnf -y install runc gcc-c++ zip

echo "Starting the IBI cluster"
make ibi-iso ibi-vm ibi-logs

echo "Attaching and configuring the cluster"
make build-openshift-install imagebasedconfig.iso ibi-attach-config.iso

echo "Rebooting the cluster"
make ibi-reboot wait-for-ibi

EOF

chmod +x ${SHARED_DIR}/image_based_install.sh

echo "Transfering install script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/image_based_install.sh $ssh_host_ip:$remote_workdir

echo "Transferring pull secrets..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.pull_secret.json $ssh_host_ip:$remote_workdir
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.backup_secret.json $ssh_host_ip:$remote_workdir

echo "Installing target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/image_based_install.sh"
