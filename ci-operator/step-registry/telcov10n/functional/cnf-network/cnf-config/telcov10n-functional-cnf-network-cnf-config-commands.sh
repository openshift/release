#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Create group_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all ${ECO_CI_CD_INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/bastions ${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions

echo "Create host_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion ${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

cd /eco-ci-cd/
ansible-playbook ./playbooks/cnf/deploy-cnf-config.yaml -i ./inventories/ocp-deployment/deploy-ocp-hybrid-multinode.yml \
    --extra-vars kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig
