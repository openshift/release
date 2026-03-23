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

if [[ "$OPERATORS" == *"fbc"* ]]; then
  export DISCONNECTED="true"
fi

echo $DISCONNECTED > ${SHARED_DIR}/disconnected

EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
EXTRA_VARS="${EXTRA_VARS} version=${VERSION}"
EXTRA_VARS="${EXTRA_VARS} disconnected=${DISCONNECTED}"
EXTRA_VARS="${EXTRA_VARS} operators='${OPERATORS}'"

cd /eco-ci-cd/
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "${EXTRA_VARS}"
