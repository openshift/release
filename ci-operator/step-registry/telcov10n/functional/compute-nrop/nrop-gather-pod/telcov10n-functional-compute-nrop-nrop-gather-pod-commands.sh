#!/bin/bash
set -e
set -o pipefail
set -x

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

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

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

echo "Running must Gather"

cd /eco-ci-cd/
EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
EXTRA_VARS="${EXTRA_VARS} scope=${SCOPE}"
EXTRA_VARS="${EXTRA_VARS} test_env=${TEST_ENV}"

ansible-playbook ./playbooks/compute/nrop_must_gather.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "${EXTRA_VARS}"


echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "/tmp/temp_ssh_key"

chmod 600 "/tmp/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Copy must gather to artifacts directory"

scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key \
  "${BASTION_USER}@${BASTION_IP}":/tmp/wip/artifacts/*.gz "${ARTIFACT_DIR}"


