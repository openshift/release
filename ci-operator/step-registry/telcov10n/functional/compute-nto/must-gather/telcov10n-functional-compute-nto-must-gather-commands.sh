#!/bin/bash
set -e
set -o pipefail


ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
    echo "Detected skip.txt file — skipping the job"
    exit 0
fi

# backwards compatibility for process inventory step
if [[ -f "${SHARED_DIR}/process-inventory-completed" ]]; then
    echo "Copy inventory files"
    mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/group_vars
    mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/host_vars

    for file in ${SHARED_DIR}/*; do 
        if [[ "$file" == *"group_vars_"* || "$file" == *"host_vars_"* ]]; then
            DEST_DIR=$( basename $file | cut -d'_' -f1,2 )
            DEST_FILE=$( basename $file | cut -d'_' -f3 )
            cp $file ${ECO_CI_CD_INVENTORY_PATH}/$DEST_DIR/$DEST_FILE
        fi
    done
else

    echo "Create group_vars directory"
    mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

    echo "Copy group inventory files"
    # shellcheck disable=SC2154
    cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
    cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

    echo "Create host_vars directory"
    mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

    echo "Copy host inventory files"
    cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

fi

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Configure compute and NTO cluster settings"
cd /eco-ci-cd/

# Prepare extra variables for ansible playbook
EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Running ansible-playbook with extra vars: ${EXTRA_VARS}"
export ANSIBLE_REMOTE_TEMP="/tmp"
ansible-playbook ./playbooks/compute/must-gather.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "${EXTRA_VARS}"


echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "/tmp/temp_ssh_key"

chmod 600 "/tmp/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Archive must gather"
# Temporarily disable set -e to capture SSH exit code
set +e
timeout -s 9 "${ECO_GOTESTS_SSH_TIMEOUT}" ssh \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    "${BASTION_USER}@${BASTION_IP}" -i /tmp/temp_ssh_key bash -s -- << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

tar -czvf /artifacts/must-gather.tar.gz /must-gather 

EOF

echo "Copy must gather to artifacts directory"

scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key \
  "${BASTION_USER}@${BASTION_IP}":/artifacts/must-gather.tar.gz "${ARTIFACT_DIR}/must-gather.tar.gz"

