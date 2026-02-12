#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Create group_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files from SHARED_DIR"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp ${SHARED_DIR}/hypervisors /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
cp ${SHARED_DIR}/nodes /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
cp ${SHARED_DIR}/masters /eco-ci-cd/inventories/ocp-deployment/group_vars/masters

echo "Create host_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/hypervisor /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
cp ${SHARED_DIR}/master0 /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/kni-qe-99/auth/kubeconfig"

cd /eco-ci-cd
ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=${VERSION} disconnected=true mirror_only=true operators='$SPOKE_OPERATORS' ocp_operator_mirror_skip_internal_registry_cleanup=true"

