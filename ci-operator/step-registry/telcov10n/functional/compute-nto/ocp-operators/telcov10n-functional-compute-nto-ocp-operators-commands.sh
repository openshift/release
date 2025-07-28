#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Checking OPERATORS environment variable..."
echo "OPERATORS=${OPERATORS}"

# Check if OPERATORS is empty list - if so, skip operator installation
if [[ "${OPERATORS}" == "[]" ]]; then
  echo "OPERATORS is empty list '[]' - no operators to install for compute-nto domain"
  echo "Exiting successfully as no operator installation is required"
  exit 0
fi

echo "Create group_vars directory"
mkdir -pv /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

echo "Create host_vars directory"
mkdir -pv /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

cd /eco-ci-cd/
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" operators='${OPERATORS}'"