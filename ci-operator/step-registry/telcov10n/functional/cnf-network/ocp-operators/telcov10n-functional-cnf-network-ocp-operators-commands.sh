#!/bin/bash
set -e
set -o pipefail

echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

cd /eco-ci-cd/
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/deploy-ocp-hybrid-multinode.yml \
    --extra-vars "kubeconfig="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" version=${VERSION} operators='${OPERATORS}'"
