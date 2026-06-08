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
    echo "ERROR: inventory not processed"
    exit 1
fi

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME="${CLUSTER_NAME}"

# Prepare extra variables for ansible playbook
# OCP configuration variables
EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

echo "Deploy OCP cluster upgrade"
ansible-playbook ./playbooks/compute/cluster_upgrade.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "${EXTRA_VARS}"
