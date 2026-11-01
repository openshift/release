#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

# The target hub deployment writes this before MinIO and before seed inventory is restored.
TARGET_HUB_CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
if [[ -z "${TARGET_HUB_CLUSTER_NAME}" ]]; then
  echo "Target hub cluster name is missing from SHARED_DIR/cluster_name" >&2
  exit 1
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

cd /eco-ci-cd/

echo "Deploying MinIO on target bastion"
ansible-playbook playbooks/ran/ibu-deploy-minio.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --extra-vars "minio_oadp_hub_kubeconfig=/home/telcov10n/project/generated/${TARGET_HUB_CLUSTER_NAME}/auth/kubeconfig" \
  -vv
