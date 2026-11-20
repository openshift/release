#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

cd /eco-ci-cd/

# Publish OADP credentials when an IBU target hub is available.
HUB_KUBECONFIG=""
if [ -f "${SHARED_DIR}/cluster_name" ]; then
  HUB_KUBECONFIG="/home/telcov10n/project/generated/$(cat "${SHARED_DIR}/cluster_name")/auth/kubeconfig"
fi

echo "Deploying MinIO on target bastion"
ansible-playbook playbooks/ran/ibu-deploy-minio.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --extra-vars "minio_oadp_hub_kubeconfig=${HUB_KUBECONFIG}" -vv
