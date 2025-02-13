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
export IBI_VM_NAME="${TARGET_VM_NAME}"
export OPENSHIFT_INSTALLER_BIN="/usr/bin/openshift-install"

cd ${remote_workdir}/ib-orchestrate-vm

export REGISTRY_AUTH_FILE='${remote_workdir}/.pull_secret.json'
export PULL_SECRET=\$(<\$REGISTRY_AUTH_FILE)
export BACKUP_SECRET=\$(<${remote_workdir}/.backup_secret.json)

sudo dnf -y install runc crun gcc-c++ zip

mkdir tmp
podman run -v ./tmp:/tmp:Z --user root:root --rm --entrypoint='["/bin/sh","-c"]' ${INSTALLER_PULL_REF} "cp /bin/openshift-install /tmp/openshift-install"
sudo mv ./tmp/openshift-install /usr/bin/openshift-install
rm -rf tmp

echo "Creating the IBI installation iso"
SECONDS=0
make ibi-iso
t_ibi_iso_create=\$SECONDS

echo "Installing via IBI"
SECONDS=0
make ibi-vm ibi-logs
t_ibi_install=\$SECONDS

echo "Attaching and configuring the cluster"
SECONDS=0
make imagebasedconfig.iso ibi-attach-config.iso
t_ibi_config=\$SECONDS

echo "Rebooting the cluster"
SECONDS=0
make ibi-reboot wait-for-ibi
t_ibi_config_reboot=\$SECONDS

echo "IBI Times:"
echo "ISO Creation: \${t_ibi_iso_create} seconds"
echo "Installation Time: \${t_ibi_install} seconds"
echo "Config Time: \${t_ibi_config} seconds"
echo "Config Reboot Time: \${t_ibi_config_reboot} seconds"
EOF

chmod +x ${SHARED_DIR}/image_based_install.sh

echo "Transfering install script..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/image_based_install.sh $ssh_host_ip:$remote_workdir

echo "Transferring pull secrets..."
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.pull_secret.json $ssh_host_ip:$remote_workdir
scp "${SSHOPTS[@]}" ${SHARED_DIR}/.backup_secret.json $ssh_host_ip:$remote_workdir

echo "Installing target cluster..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/image_based_install.sh"
